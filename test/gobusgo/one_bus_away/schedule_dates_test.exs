defmodule Gobusgo.OneBusAway.ScheduleDatesTest do
  # Verifies which dates of a route are due as a pure function of the time
  # and the dates the route knows. Each time is placed around the route's
  # own slot, read from RouteSchedule, so the cases hold for any slot.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.RouteSchedule
  alias Gobusgo.OneBusAway.ScheduleDates

  @route_id "1_100479"
  @today ~D[2026-11-07]
  @yesterday ~D[2026-11-06]
  @tomorrow ~D[2026-11-08]

  defp slot_time(offset_seconds) do
    @today
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.add(RouteSchedule.slot_minute(@route_id) * 60 + offset_seconds, :second)
  end

  defp due(known_dates, now) do
    ScheduleDates.due(%{route_id: @route_id, known_dates: known_dates, now: now})
  end

  # The cases before the slot need a slot after midnight.
  setup do
    assert RouteSchedule.slot_minute(@route_id) >= 1
    :ok
  end

  for {name, known_dates, offset_seconds, expected} <- [
        {"before the slot, with nothing known, the day before and the UTC date", [], -1,
         [@yesterday, @today]},
        {"at the slot, with nothing known, the next date too", [], 0,
         [@yesterday, @today, @tomorrow]},
        {"at the slot, with the two earlier dates known, the next date alone",
         [@yesterday, @today], 0, [@tomorrow]},
        {"at the slot, with every date known, nothing", [@yesterday, @today, @tomorrow], 0, []},
        {"before the slot, with the two earlier dates known, nothing", [@yesterday, @today], -1,
         []}
      ] do
    test "is due: #{name}" do
      assert due(unquote(Macro.escape(known_dates)), slot_time(unquote(offset_seconds))) ==
               unquote(Macro.escape(expected))
    end
  end

  test "is due, at the end of the UTC day, for the next date with the earlier dates known" do
    assert due([@yesterday, @today], ~U[2026-11-07 23:59:59Z]) == [@tomorrow]
  end
end
