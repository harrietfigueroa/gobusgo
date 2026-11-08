defmodule Gobusgo.OneBusAway.RouteScheduleView.StateTest do
  # Verifies the rules of the route schedule view as pure functions: fetches
  # are written out by hand, put in sequence, and the outcome and the dates
  # each route keeps are read back.
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

  test "keeps two service dates per route" do
    assert State.service_date_count_max() == 2
  end

  test "switches to the first fetch of a route" do
    assert {_state, {:switched, []}} = State.put(State.new(8), fetch("1_A", ~D[2026-11-07]))
  end

  test "holds a second service date beside the first" do
    state = put_all(State.new(8), [fetch("1_A", ~D[2026-11-07]), fetch("1_A", ~D[2026-11-08])])

    assert State.service_dates(state) == %{"1_A" => [~D[2026-11-07], ~D[2026-11-08]]}
  end

  test "drops the earliest date for a third, later one" do
    state = put_all(State.new(8), [fetch("1_A", ~D[2026-11-07]), fetch("1_A", ~D[2026-11-08])])

    assert {state, {:switched, [~D[2026-11-07]]}} = State.put(state, fetch("1_A", ~D[2026-11-09]))
    assert State.service_dates(state) == %{"1_A" => [~D[2026-11-08], ~D[2026-11-09]]}
  end

  test "ignores a date earlier than both it holds" do
    state = put_all(State.new(8), [fetch("1_A", ~D[2026-11-07]), fetch("1_A", ~D[2026-11-08])])

    assert {^state, :ignored} = State.put(state, fetch("1_A", ~D[2026-11-06]))
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
end
