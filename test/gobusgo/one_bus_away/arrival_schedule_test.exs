defmodule Gobusgo.OneBusAway.ArrivalScheduleTest do
  # Verifies which open stops are due as a pure function of the stops, the
  # fetch time each has, and the time it is, all written out by hand.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.ArrivalSchedule

  @now ~U[2026-10-07 02:30:00Z]

  defp ago(seconds), do: DateTime.add(@now, -seconds, :second)

  defp due(stop_ids, fetch_times) do
    ArrivalSchedule.due(%{stop_ids: stop_ids, fetch_times: fetch_times, now: @now})
  end

  test "the refresh age is five minutes" do
    assert ArrivalSchedule.refresh_age_ms() == 300_000
  end

  test "no stop is due when no stop is open" do
    assert due([], %{"1_100" => ago(900)}) == []
  end

  test "a stop with no fetch is due" do
    assert due(["1_100"], %{}) == ["1_100"]
  end

  for {name, age_seconds, due?} <- [
        {"just fetched", 0, false},
        {"fetched one second short of five minutes ago", 299, false},
        {"fetched five minutes ago", 300, true},
        {"fetched an hour ago", 3_600, true}
      ] do
    test "a stop #{name} is #{if due?, do: "due", else: "not due"}" do
      expected =
        case unquote(due?) do
          true -> ["1_100"]
          false -> []
        end

      assert due(["1_100"], %{"1_100" => ago(unquote(age_seconds))}) == expected
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
