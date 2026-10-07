defmodule Gobusgo.OneBusAway.ArrivalScheduleTest do
  # Verifies which open stops are due as a pure function of the stops, the
  # fetch time each has, the time it is, and the refresh age, all written
  # out by hand.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.ArrivalSchedule

  @now ~U[2026-10-07 02:30:00Z]

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

  @refresh_age_ms 300_000

  defp due(stop_ids, fetch_times, refresh_age_ms \\ @refresh_age_ms) do
    ArrivalSchedule.due(%{
      stop_ids: stop_ids,
      fetch_times: fetch_times,
      now: @now,
      refresh_age_ms: refresh_age_ms
    })
  end

  test "no stop is due when no stop is open" do
    assert due([], %{"1_100" => ago(900)}) == []
  end

  test "a stop with no fetch is due" do
    assert due(["1_100"], %{}) == ["1_100"]
  end

  # Each row is a refresh age, the age of a stop's fetch, and whether the
  # stop is due: for each of three ages, a fetch one millisecond short of
  # it and a fetch exactly at it, then a fetch just made and one far past.
  for {refresh_age_ms, fetch_age_ms, due?} <- [
        {30_000, 29_999, false},
        {30_000, 30_000, true},
        {35_000, 34_999, false},
        {35_000, 35_000, true},
        {300_000, 299_999, false},
        {300_000, 300_000, true},
        {300_000, 0, false},
        {30_000, 3_600_000, true}
      ] do
    test "a stop fetched #{fetch_age_ms} ms ago is #{if due?, do: "due", else: "not due"} at a refresh age of #{refresh_age_ms} ms" do
      fetched_at = DateTime.add(@now, -unquote(fetch_age_ms), :millisecond)

      expected =
        case unquote(due?) do
          true -> ["1_100"]
          false -> []
        end

      assert due(["1_100"], %{"1_100" => fetched_at}, unquote(refresh_age_ms)) == expected
    end
  end

  for refresh_age_ms <- [0, -1, 30_000.0, nil] do
    test "refuses the refresh age #{inspect(refresh_age_ms)}, which is not a positive integer" do
      assert_raise Gobusgo.Assert.AssertionError, ~r/refresh_age_ms/, fn ->
        due(["1_100"], %{}, unquote(refresh_age_ms))
      end
    end
  end

  test "the stops with no fetch come first, in identifier order" do
    fetch_times = %{"1_300" => ago(900)}

    assert due(["1_300", "1_200", "1_100"], fetch_times) == ["1_100", "1_200", "1_300"]
  end

  test "the stops with a stale fetch follow, the oldest fetch first" do
    fetch_times = %{"1_100" => ago(400), "1_200" => ago(900), "1_300" => ago(600)}

    assert due(["1_100", "1_200", "1_300"], fetch_times) == ["1_200", "1_300", "1_100"]
  end

  test "two stops fetched at one time come in identifier order" do
    fetch_times = %{"1_200" => ago(600), "1_100" => ago(600)}

    assert due(["1_200", "1_100"], fetch_times) == ["1_100", "1_200"]
  end

  test "a stop that is not open is not due, whatever its fetch" do
    assert due(["1_100"], %{"1_999" => ago(900)}) == ["1_100"]
  end

  test "a stop named twice is due once" do
    assert due(["1_100", "1_100"], %{}) == ["1_100"]
  end
end
