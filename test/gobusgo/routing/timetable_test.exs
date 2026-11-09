defmodule Gobusgo.Routing.TimetableTest do
  # Verifies the timetable as a pure function of compact schedules written
  # out by hand: one route of two stops a trip, with the previous service
  # date's trips placed around midnight, on an ordinary day and across the
  # change from daylight saving time.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.CompactSchedule
  alias Gobusgo.Routing.SnapshotFormat
  alias Gobusgo.Routing.Timetable

  # 2026-11-07 and 2026-11-08 at midnight in Seattle; 2026-11-01, the end of
  # daylight saving time, is 25 hours long.
  @start_ms 1_794_038_400_000
  @previous_start_ms @start_ms - 86_400_000
  @long_day_start_ms 1_793_520_000_000
  @long_day_previous_start_ms @long_day_start_ms - 90_000_000

  defp schedule(%{start_ms: start_ms, trips: trips}) do
    {:ok, compact} =
      CompactSchedule.pack(%{
        route_id: "1_R",
        schedule_date_ms: start_ms,
        service_ids: ["s"],
        stop_ids: ["1_A", "1_B", "1_C"],
        trips:
          for {id, times} <- trips do
            count = length(times)

            %{
              id: id,
              direction_id: "0",
              headsign: nil,
              block_id: nil,
              service_id: "s",
              shape_id: nil,
              stop_indexes: Enum.take([0, 1, 2], count),
              arrival_s: times,
              departure_s: times,
              arrival_enabled: List.duplicate(true, count),
              departure_enabled: [true | List.duplicate(false, count - 1)]
            }
          end
      })

    compact
  end

  # The timetable with its packed connection records read back as maps.
  defp build(trips, previous_trips, starts \\ {@start_ms, @previous_start_ms}) do
    {start_ms, previous_start_ms} = starts

    previous =
      for trips <- [previous_trips],
          trips != [],
          do: schedule(%{start_ms: previous_start_ms, trips: trips})

    timetable =
      Timetable.build(%{
        service_date: ~D[2026-11-08],
        schedules: [schedule(%{start_ms: start_ms, trips: trips})],
        previous_schedules: previous
      })

    file = SnapshotFormat.encode_packed(:connections, timetable.connections)
    {:ok, %{records: connections}} = SnapshotFormat.decode(file)
    %{timetable | connections: connections}
  end

  test "counts the connection records it packs" do
    timetable = build([{"t1", [3_600, 3_900, 4_200]}, {"t2", [100, 200]}], [])

    assert timetable.connection_count == 3
    assert length(timetable.connections) == 3
  end

  test "orders connections that depart together by arrival, then trip" do
    timetable = build([{"t2", [100, 200]}, {"t1", [100, 300]}, {"t3", [100, 200]}], [])

    assert Enum.map(timetable.connections, &{&1.arrival_s, &1.trip}) ==
             [{200, 1}, {200, 2}, {300, 0}]
  end

  test "makes one connection per hop of a trip, from one stop's departure to the next stop's arrival" do
    timetable = build([{"t1", [3_600, 3_900, 4_200]}], [])

    assert Enum.map(timetable.connections, &{&1.departure_s, &1.arrival_s, &1.sequence}) ==
             [{3_600, 3_900, 0}, {3_900, 4_200, 1}]
  end

  test "names stops and trips by index in identifier order" do
    timetable = build([{"t2", [100, 200]}, {"t1", [300, 400, 500]}], [])

    assert timetable.stop_ids == ["1_A", "1_B", "1_C"]
    assert Enum.map(timetable.trips, & &1.id) == ["t1", "t2"]
  end

  test "orders connections by departure across trips" do
    timetable = build([{"t1", [500, 600]}, {"t2", [100, 900]}], [])

    assert Enum.map(timetable.connections, & &1.departure_s) == [100, 500]
  end

  test "takes boarding from the departure stop and alighting from the arrival stop" do
    [first, second] = build([{"t1", [100, 200, 300]}], []).connections

    assert {first.boarding, first.alighting} == {true, true}
    assert {second.boarding, second.alighting} == {false, true}
  end

  test "folds in the previous date's hops that depart after midnight, shifted back a day" do
    timetable = build([{"t1", [3_600, 3_900]}], [{"late", [86_000, 86_500, 87_000]}])

    assert timetable.previous_date_included

    assert [%{id: "late", service_day_offset: 1}] =
             Enum.filter(timetable.trips, &(&1.service_day_offset == 1))

    previous =
      for connection <- timetable.connections,
          Enum.at(timetable.trips, connection.trip).id == "late",
          do: {connection.departure_s, connection.sequence}

    assert previous == [{100, 1}]
  end

  test "keeps a trip of the previous date apart from the same trip of this date" do
    timetable = build([{"t1", [3_600, 3_900]}], [{"t1", [86_500, 86_700]}])

    assert Enum.map(timetable.trips, &{&1.id, &1.service_day_offset}) == [{"t1", 0}, {"t1", 1}]
  end

  test "shifts the previous date's hops by 25 hours after the end of daylight saving time" do
    timetable =
      build(
        [{"t1", [3_600, 3_900]}],
        [{"late", [90_100, 90_400]}],
        {@long_day_start_ms, @long_day_previous_start_ms}
      )

    assert [%{departure_s: 100, arrival_s: 400}] =
             Enum.filter(timetable.connections, &(&1.trip == 1))
  end

  test "includes no previous date when none is given" do
    refute build([{"t1", [100, 200]}], []).previous_date_included
  end

  test "names the start of the snapshot's service day" do
    assert build([{"t1", [100, 200]}], []).service_day_start_ms == @start_ms
  end

  test "orders connections by departure across hours, whatever order the trips come in" do
    timetable =
      build([{"t3", [7_300, 7_400]}, {"t1", [3_500, 7_300]}, {"t2", [3_700, 3_800]}], [])

    assert Enum.map(timetable.connections, &{&1.departure_s, &1.trip}) ==
             [{3_500, 0}, {3_700, 1}, {7_300, 2}]
  end

  test "builds the same timetable from streams of schedules as from lists" do
    today = [schedule(%{start_ms: @start_ms, trips: [{"t1", [100, 200, 300]}]})]

    previous = [
      schedule(%{start_ms: @previous_start_ms, trips: [{"t0", [86_350, 86_500, 86_600]}]})
    ]

    listed = %{service_date: ~D[2026-11-08], schedules: today, previous_schedules: previous}

    streamed = %{
      listed
      | schedules: Stream.concat([today]),
        previous_schedules: Stream.concat([previous])
    }

    assert Timetable.build(streamed) == Timetable.build(listed)
  end
end
