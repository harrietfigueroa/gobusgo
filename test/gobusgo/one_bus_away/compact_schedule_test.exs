defmodule Gobusgo.OneBusAway.CompactScheduleTest do
  # Verifies the compact form as a pure function of a schedule: a schedule
  # parsed from the live fixture is listed, packed, and unpacked trip by
  # trip, and comes back as it went in; lists that break a packing rule are
  # built from a valid listing with one field overridden.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.CompactSchedule
  alias Gobusgo.OneBusAway.RouteSchedules

  @fixture_path Path.expand("../../fixtures/one_bus_away/schedule_for_route.json", __DIR__)

  defp schedule do
    data = @fixture_path |> File.read!() |> JSON.decode!() |> Map.fetch!("data")
    {:ok, schedule} = RouteSchedules.parse(data, "19_41")
    schedule
  end

  defp packed do
    {:ok, compact} = schedule() |> CompactSchedule.list() |> CompactSchedule.pack()
    compact
  end

  defp with_first_trip(listed, changes) do
    [trip | trips] = listed.trips
    %{listed | trips: [Map.merge(trip, changes) | trips]}
  end

  describe "list/1" do
    test "holds each stop the trips serve once" do
      listed = CompactSchedule.list(schedule())

      assert listed.stop_ids == Enum.uniq(listed.stop_ids)

      assert MapSet.new(listed.stop_ids) ==
               MapSet.new(
                 for trip <- schedule().trips, stop_time <- trip.stop_times, do: stop_time.stop_id
               )
    end
  end

  describe "pack/1 and stop_times/2" do
    test "give back every trip's stop times as they were" do
      compact = packed()

      assert Enum.map(compact.trips, &CompactSchedule.stop_times(compact, &1)) ==
               Enum.map(schedule().trips, & &1.stop_times)
    end

    test "keep every trip's own fields" do
      fields = [:id, :direction_id, :headsign, :block_id, :service_id, :shape_id]

      assert Enum.map(packed().trips, &Map.take(&1, fields)) ==
               Enum.map(schedule().trips, &Map.take(&1, fields))
    end

    test "count the stop times of every trip" do
      assert packed().stop_time_count ==
               Enum.sum_by(schedule().trips, &length(&1.stop_times))
    end

    test "take 11 bytes of binaries per stop time" do
      compact = packed()

      bytes =
        Enum.sum_by(compact.trips, fn trip ->
          byte_size(trip.stop_indexes) + byte_size(trip.arrival_s) +
            byte_size(trip.departure_s) + byte_size(trip.enabled_flags)
        end)

      assert bytes == 11 * compact.stop_time_count
    end
  end

  describe "pack/1 refusals" do
    test "refuses a trip whose lists differ in length" do
      listed = CompactSchedule.list(schedule())
      [%{id: trip_id} | _trips] = listed.trips

      assert CompactSchedule.pack(with_first_trip(listed, %{arrival_s: []})) ==
               {:error, {:length_mismatch, trip_id}}
    end

    test "refuses a trip with no stop times" do
      listed = CompactSchedule.list(schedule())
      [%{id: trip_id} | _trips] = listed.trips
      fields = [:stop_indexes, :arrival_s, :departure_s, :arrival_enabled, :departure_enabled]

      assert CompactSchedule.pack(with_first_trip(listed, Map.new(fields, &{&1, []}))) ==
               {:error, {:length_mismatch, trip_id}}
    end

    test "refuses a stop index past the route's stops" do
      listed = CompactSchedule.list(schedule())
      [%{id: trip_id, stop_indexes: indexes} | _trips] = listed.trips
      indexes = List.replace_at(indexes, 0, length(listed.stop_ids))

      assert CompactSchedule.pack(with_first_trip(listed, %{stop_indexes: indexes})) ==
               {:error, {:index_out_of_range, trip_id}}
    end

    test "refuses a negative time" do
      listed = CompactSchedule.list(schedule())
      [%{id: trip_id, departure_s: departures} | _trips] = listed.trips
      departures = List.replace_at(departures, 0, -1)

      assert CompactSchedule.pack(with_first_trip(listed, %{departure_s: departures})) ==
               {:error, {:time_out_of_range, trip_id}}
    end

    test "refuses more stops than a 16-bit index reaches" do
      listed = CompactSchedule.list(schedule())
      stop_ids = for index <- 0..0xFFFF, do: "stop-#{index}"

      assert CompactSchedule.pack(%{listed | stop_ids: ["extra" | stop_ids]}) ==
               {:error, :stop_count_exceeded}
    end
  end
end
