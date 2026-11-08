defmodule Gobusgo.OneBusAway.RouteScheduleView.StateTest do
  # Verifies the rules of the route schedule view as pure functions: fetches
  # and attempts are written out by hand, put in sequence, and the outcome
  # and the dates each route keeps are read back.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.RouteScheduleView.State

  @request_a "0199c4a2-7e1b-7a3f-9d20-00000000000a"
  @request_b "0199c4a2-7e1b-7a3f-9d20-00000000000b"

  defp fetch(route_id, service_date, overrides \\ %{}) do
    Map.merge(
      %{
        id: route_id,
        service_date: service_date,
        request_id: @request_a,
        fetched_at: ~U[2026-11-07 03:00:00Z]
      },
      overrides
    )
  end

  defp put_all(state, fetches) do
    Enum.reduce(fetches, state, fn fetch, state ->
      {state, _outcome} = State.put(state, fetch)
      state
    end)
  end

  defp three_dates do
    put_all(State.new(8), [
      fetch("1_A", ~D[2026-11-06]),
      fetch("1_A", ~D[2026-11-07]),
      fetch("1_A", ~D[2026-11-08])
    ])
  end

  test "keeps three service dates per route" do
    assert State.service_date_count_max() == 3
  end

  test "switches to the first fetch of a route" do
    assert {_state, {:switched, []}} = State.put(State.new(8), fetch("1_A", ~D[2026-11-07]))
  end

  test "holds three service dates side by side" do
    assert State.service_dates(three_dates()) ==
             %{"1_A" => [~D[2026-11-06], ~D[2026-11-07], ~D[2026-11-08]]}
  end

  test "drops the earliest date for a fourth, later one" do
    assert {state, {:switched, [~D[2026-11-06]]}} =
             State.put(three_dates(), fetch("1_A", ~D[2026-11-09]))

    assert State.service_dates(state) ==
             %{"1_A" => [~D[2026-11-07], ~D[2026-11-08], ~D[2026-11-09]]}
  end

  test "ignores a date earlier than all it holds" do
    state = three_dates()

    assert {^state, :ignored} = State.put(state, fetch("1_A", ~D[2026-11-05]))
  end

  for {name, overrides, outcome} <- [
        {"the same fetch again", %{}, :ignored},
        {"an older fetch", %{request_id: @request_b, fetched_at: ~U[2026-11-07 02:00:00Z]},
         :ignored},
        {"a newer fetch", %{request_id: @request_b, fetched_at: ~U[2026-11-07 04:00:00Z]},
         {:switched, []}},
        {"another fetch at the same time", %{request_id: @request_b}, {:switched, []}}
      ] do
    test "for a held route and date, #{name} gives #{inspect(outcome)}" do
      state = put_all(State.new(8), [fetch("1_A", ~D[2026-11-07])])

      assert {_state, unquote(Macro.escape(outcome))} =
               State.put(state, fetch("1_A", ~D[2026-11-07], unquote(Macro.escape(overrides))))
    end
  end

  test "ignores a route beyond the bound" do
    state = put_all(State.new(1), [fetch("1_A", ~D[2026-11-07])])

    assert {^state, :ignored} = State.put(state, fetch("1_B", ~D[2026-11-07]))
  end

  test "takes another date of a held route at the bound" do
    state = put_all(State.new(1), [fetch("1_A", ~D[2026-11-07])])

    assert {_state, {:switched, []}} = State.put(state, fetch("1_A", ~D[2026-11-08]))
  end

  describe "attempt/2" do
    test "notes a date of a route" do
      {state, []} = State.attempt(State.new(8), %{route_id: "1_A", service_date: ~D[2026-11-07]})

      assert State.attempts(state) == %{"1_A" => [~D[2026-11-07]]}
    end

    test "drops the earliest attempted date for a fourth, later one" do
      state =
        Enum.reduce(6..8, State.new(8), fn day, state ->
          {state, _removed} =
            State.attempt(state, %{route_id: "1_A", service_date: Date.new!(2026, 11, day)})

          state
        end)

      assert {state, [~D[2026-11-06]]} =
               State.attempt(state, %{route_id: "1_A", service_date: ~D[2026-11-09]})

      assert State.attempts(state) == %{"1_A" => [~D[2026-11-07], ~D[2026-11-08], ~D[2026-11-09]]}
    end

    test "ignores a route beyond the bound" do
      {state, []} = State.attempt(State.new(1), %{route_id: "1_A", service_date: ~D[2026-11-07]})

      assert {^state, []} = State.attempt(state, %{route_id: "1_B", service_date: ~D[2026-11-07]})
    end
  end
end
