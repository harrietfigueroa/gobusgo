defmodule Gobusgo.OneBusAway.RouteScheduleTest do
  # Verifies the refresh rules as pure functions of an identifier, its last
  # fetch time, and the current time. The times are written around the slot
  # the identifier under test has, which the tests read from the module.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.RouteSchedule

  @id "40_100479"
  @day ~D[2026-10-05]

  # The time `offset_seconds` after the slot of `@id` on `date`.
  defp around_slot(date, offset_seconds) do
    date
    |> DateTime.new!(~T[00:00:00], "Etc/UTC")
    |> DateTime.add(RouteSchedule.slot_minute(@id) * 60 + offset_seconds, :second)
  end

  describe "slot_minute/1" do
    test "is a minute of the day" do
      for id <- ["1", "40", "40_100479", "1_100224", "95_2116"] do
        assert RouteSchedule.slot_minute(id) in 0..1439
      end
    end

    test "is the same for the same identifier" do
      assert RouteSchedule.slot_minute(@id) == RouteSchedule.slot_minute(@id)
    end

    test "is the hash the decision names, so a slot outlives a restart" do
      assert RouteSchedule.slot_minute(@id) == :erlang.phash2(@id, 1440)
    end

    test "spreads a few hundred identifiers over most of the day's hours" do
      hours =
        for index <- 1..391, uniq: true, do: div(RouteSchedule.slot_minute("1_#{index}"), 60)

      assert length(hours) == 24
    end
  end

  describe "slot_at/2" do
    test "is today's slot once the slot has come" do
      assert RouteSchedule.slot_at(@id, around_slot(@day, 1)) == around_slot(@day, 0)
    end

    test "is today's slot at the slot's own instant" do
      assert RouteSchedule.slot_at(@id, around_slot(@day, 0)) == around_slot(@day, 0)
    end

    test "is yesterday's slot before today's has come" do
      assert RouteSchedule.slot_at(@id, around_slot(@day, -1)) ==
               around_slot(Date.add(@day, -1), 0)
    end
  end

  describe "due?/1" do
    test "is true for an identifier that has no fetch" do
      assert RouteSchedule.due?(%{id: @id, fetched_at: nil, now: around_slot(@day, 0)})
    end

    test "is true when the last fetch is from before the latest slot" do
      assert RouteSchedule.due?(%{
               id: @id,
               fetched_at: around_slot(@day, -1),
               now: around_slot(@day, 30)
             })
    end

    test "is false when the last fetch is from the latest slot or after it" do
      refute RouteSchedule.due?(%{
               id: @id,
               fetched_at: around_slot(@day, 0),
               now: around_slot(@day, 30)
             })
    end

    test "is false through the rest of the day after a fetch at the slot" do
      refute RouteSchedule.due?(%{
               id: @id,
               fetched_at: around_slot(@day, 5),
               now: around_slot(Date.add(@day, 1), -1)
             })
    end

    test "is true again when the next day's slot comes" do
      assert RouteSchedule.due?(%{
               id: @id,
               fetched_at: around_slot(@day, 5),
               now: around_slot(Date.add(@day, 1), 0)
             })
    end

    test "is true for a fetch several days old, whatever the minute" do
      assert RouteSchedule.due?(%{
               id: @id,
               fetched_at: around_slot(Date.add(@day, -3), 5),
               now: around_slot(@day, -600)
             })
    end
  end
end
