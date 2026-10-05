defmodule Gobusgo.OneBusAway.StopView.StateTest do
  # Verifies the rules of the stop view as pure functions: each case puts
  # fetches into a state and reads the outcomes, which name the stops to
  # hold and the stops removed, and the number of stops held.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.StopView.State

  @first_request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @second_request_id "0199c4a2-7e1b-7a3f-9d20-000000000002"
  @third_request_id "0199c4a2-7e1b-7a3f-9d20-000000000003"
  @earlier ~U[2026-10-05 01:00:00Z]
  @later ~U[2026-10-05 02:00:00Z]

  defp stop(id, name \\ "a stop"), do: %{"id" => id, "name" => name}

  defp fetch(overrides) do
    Map.merge(
      %{
        id: "40_1",
        request_id: @first_request_id,
        fetched_at: @earlier,
        stops: [stop("a"), stop("b")],
        parent_stops: []
      },
      overrides
    )
  end

  defp put_all(fetches, bounds \\ %{}) do
    state = State.new(Map.merge(%{route_count_max: 8, stop_count_max: 8}, bounds))

    Enum.reduce(fetches, {state, []}, fn fetch, {state, outcomes} ->
      {state, outcome} = State.put(state, fetch)
      {state, outcomes ++ [outcome]}
    end)
  end

  defp held_ids({:switched, %{held_stops: held_stops}}), do: Enum.map(held_stops, & &1.id)
  defp removed_ids({:switched, %{removed_ids: removed_ids}}), do: Enum.sort(removed_ids)

  test "a new view holds no stop" do
    state = State.new(%{route_count_max: 8, stop_count_max: 8})

    assert State.stop_count(state) == 0
  end

  test "the first fetch of a route holds its stops with the fetch they come from" do
    {state, [outcome]} = put_all([fetch(%{})])

    assert outcome ==
             {:switched,
              %{
                held_stops: [
                  %{
                    id: "a",
                    request_id: @first_request_id,
                    fetched_at: @earlier,
                    stop: stop("a")
                  },
                  %{id: "b", request_id: @first_request_id, fetched_at: @earlier, stop: stop("b")}
                ],
                removed_ids: []
              }}

    assert State.stop_count(state) == 2
  end

  test "a fetch holds its parent stops too" do
    {state, [outcome]} = put_all([fetch(%{parent_stops: [stop("station")]})])

    assert held_ids(outcome) == ["a", "b", "station"]
    assert State.stop_count(state) == 3
  end

  test "a newer fetch of a route replaces the values of its stops" do
    newer =
      fetch(%{request_id: @second_request_id, fetched_at: @later, stops: [stop("a", "new")]})

    {_state, [_first, outcome]} = put_all([fetch(%{stops: [stop("a")]}), newer])

    assert {:switched, %{held_stops: [held_stop]}} = outcome

    assert held_stop == %{
             id: "a",
             request_id: @second_request_id,
             fetched_at: @later,
             stop: stop("a", "new")
           }
  end

  test "a stop the route's newer fetch does not list is removed" do
    newer = fetch(%{request_id: @second_request_id, fetched_at: @later, stops: [stop("a")]})

    {state, [_first, outcome]} = put_all([fetch(%{}), newer])

    assert removed_ids(outcome) == ["b"]
    assert State.stop_count(state) == 1
  end

  test "a parent stop the route's newer fetch does not list is removed" do
    first = fetch(%{parent_stops: [stop("station")]})
    newer = fetch(%{request_id: @second_request_id, fetched_at: @later})

    {_state, [_first, outcome]} = put_all([first, newer])

    assert removed_ids(outcome) == ["station"]
  end

  test "a stop another route still lists stays when one route drops it" do
    other = fetch(%{id: "40_2", request_id: @second_request_id, stops: [stop("b")]})
    newer = fetch(%{request_id: @third_request_id, fetched_at: @later, stops: [stop("a")]})

    {state, [_first, _other, outcome]} = put_all([fetch(%{}), other, newer])

    assert removed_ids(outcome) == []
    assert State.stop_count(state) == 2
  end

  test "a stop is removed once the last route that lists it drops it" do
    other = fetch(%{id: "40_2", request_id: @second_request_id, stops: [stop("b")]})
    newer = fetch(%{request_id: @third_request_id, fetched_at: @later, stops: [stop("a")]})

    newer_other =
      fetch(%{id: "40_2", request_id: @first_request_id, fetched_at: @later, stops: []})

    {state, outcomes} = put_all([fetch(%{}), other, newer, newer_other])

    assert removed_ids(List.last(outcomes)) == ["b"]
    assert State.stop_count(state) == 1
  end

  test "a stop keeps the values of a later fetch of another route" do
    later =
      fetch(%{
        id: "40_2",
        request_id: @second_request_id,
        fetched_at: @later,
        stops: [stop("a", "new")]
      })

    {state, [_later, outcome]} = put_all([later, fetch(%{stops: [stop("a", "old")]})])

    assert held_ids(outcome) == []
    assert State.stop_count(state) == 1
  end

  test "a stop takes the values of a fetch made at the same time as its own" do
    same = fetch(%{id: "40_2", request_id: @second_request_id, stops: [stop("a", "other")]})

    {_state, [_first, outcome]} = put_all([fetch(%{stops: [stop("a")]}), same])

    assert held_ids(outcome) == ["a"]
  end

  test "an older fetch of a route is ignored" do
    newer = fetch(%{request_id: @second_request_id, fetched_at: @later})

    {_state, outcomes} = put_all([newer, fetch(%{})])

    assert List.last(outcomes) == :ignored
  end

  test "the current fetch of a route put again is ignored" do
    {_state, outcomes} = put_all([fetch(%{}), fetch(%{})])

    assert List.last(outcomes) == :ignored
  end

  test "the fetch of a route beyond the route bound is ignored" do
    other = fetch(%{id: "40_2", request_id: @second_request_id})

    {state, outcomes} = put_all([fetch(%{}), other], %{route_count_max: 1})

    assert List.last(outcomes) == :ignored
    assert State.stop_count(state) == 2
  end

  test "a fetch that would hold more stops than the bound is refused whole" do
    other = fetch(%{id: "40_2", request_id: @second_request_id, stops: [stop("b"), stop("c")]})

    {state, outcomes} = put_all([fetch(%{}), other], %{stop_count_max: 2})

    assert List.last(outcomes) == :refused
    assert State.stop_count(state) == 2
  end

  test "a refused fetch leaves its route free to switch to a fetch that fits" do
    over = fetch(%{id: "40_2", request_id: @second_request_id, stops: [stop("b"), stop("c")]})
    fits = fetch(%{id: "40_2", request_id: @second_request_id, stops: [stop("b")]})

    {_state, outcomes} = put_all([fetch(%{}), over, fits], %{stop_count_max: 2})

    assert {:switched, _change} = List.last(outcomes)
  end

  test "a fetch that drops stops fits a view that is full" do
    newer =
      fetch(%{request_id: @second_request_id, fetched_at: @later, stops: [stop("c"), stop("d")]})

    {state, outcomes} = put_all([fetch(%{}), newer], %{stop_count_max: 2})

    assert held_ids(List.last(outcomes)) == ["c", "d"]
    assert State.stop_count(state) == 2
  end

  test "a stop bound below one is a programmer error" do
    assert_raise AssertionError, fn -> State.new(%{route_count_max: 8, stop_count_max: 0}) end
  end
end
