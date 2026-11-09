defmodule Gobusgo.Routing.Timetable do
  @ms_per_second 1_000

  @moduledoc """
  The connections of one service date, the routing core of a snapshot.
  Everything here is pure.

  A connection is one hop of a trip, from one of its stops to the next:
  it departs at the first stop's departure and arrives at the next stop's
  arrival. Its times are seconds from the start of the snapshot's service
  day, the `schedule_date_ms` OneBusAway gives each schedule, so a trip
  past midnight runs past #{24 * 3_600}.

  The trips of the previous service date that run past the start of this
  one fold in (decided in GOB-237). Their times move back by the length of
  the previous day, the difference of the two days' starts, which is 23 or
  25 hours on a change of daylight saving time, and only their connections
  that depart at or after the start of this day are kept. A trip of the
  previous date has the service day offset `1`, so it stays a trip of its
  own beside the same trip identifier of this date.

  Stops are those the connections use, in identifier order. Trips are those
  with a connection, by service day offset and then identifier.
  Connections are ordered by departure, then arrival, trip, and sequence,
  the order a connection scan reads them in. The calendar is the source's:
  OneBusAway answers each date with the services that run on it, calendar
  exceptions applied, so every trip a schedule holds runs on its date.

  The connections stay packed from the schedules' binaries to the records
  of the connections file, so no map is held per stop time, hop, or
  connection. A first pass names the stops and trips; a second writes each
  trip's records, in trip and sequence order, into one binary; and the
  records are put in connection order by sorting one integer per record
  that holds its departure, its duration, and its position in that binary.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.CompactSchedule
  alias Gobusgo.Routing.SnapshotFormat

  @type schedule :: CompactSchedule.t()

  @typedoc """
  `connections` holds the connection records in the layout of the
  connections file, without its header, in connection order;
  `connection_count` is how many.
  """
  @type t :: %{
          service_date: Date.t(),
          service_day_start_ms: integer(),
          previous_date_included: boolean(),
          route_count: non_neg_integer(),
          stop_ids: [String.t()],
          trips: [SnapshotFormat.trip()],
          connections: binary(),
          connection_count: non_neg_integer()
        }

  @doc """
  Returns the timetable of `service_date` from `schedules`, the route
  schedules of that date, and `previous_schedules`, those of the date
  before, which may be empty. Every schedule of a date must name the same
  day start.
  """
  @spec build(%{
          service_date: Date.t(),
          schedules: [schedule(), ...],
          previous_schedules: [schedule()]
        }) :: t()
  def build(
        %{service_date: %Date{} = service_date, schedules: [_first | _rest] = schedules} = input
      ) do
    previous_schedules = Map.fetch!(input, :previous_schedules)
    start_ms = day_start_ms(schedules)

    days = [
      %{schedules: schedules, offset: 0, shift_s: 0}
      | previous_day(previous_schedules, start_ms)
    ]

    named = Enum.reduce(days, %{stops: MapSet.new(), trips: MapSet.new(), runs: %{}}, &name_day/2)
    stop_ids = Enum.sort(named.stops)
    stop_index = stop_ids |> Enum.with_index() |> Map.new()
    trips = Enum.sort(named.trips)

    trip_index =
      trips
      |> Enum.with_index()
      |> Map.new(fn {{offset, id, _route}, index} -> {{offset, id}, index} end)

    unsorted = trip_records(%{runs: named.runs, trip_index: trip_index, stop_index: stop_index})

    %{
      service_date: service_date,
      service_day_start_ms: start_ms,
      previous_date_included: previous_schedules != [],
      route_count: length(schedules),
      stop_ids: stop_ids,
      trips:
        for {offset, id, route_id} <- trips do
          %{id: id, route_id: route_id, service_day_offset: offset}
        end,
      connections: in_connection_order(unsorted),
      connection_count: unsorted.count
    }
  end

  defp previous_day([], _start_ms), do: []

  defp previous_day(previous_schedules, start_ms) do
    shift_s = div(start_ms - day_start_ms(previous_schedules), @ms_per_second)
    Assert.condition(shift_s > 0, "the previous day must start before this one")
    [%{schedules: previous_schedules, offset: 1, shift_s: shift_s}]
  end

  defp day_start_ms([%{schedule_date_ms: start_ms} | _rest] = schedules) do
    Assert.condition(
      Enum.all?(schedules, &(&1.schedule_date_ms == start_ms)),
      "every schedule of a date must start at the same time"
    )

    start_ms
  end

  # The hops of `trip` that depart at or after the start of the snapshot's
  # day, their times moved back by `shift_s`, in sequence order.
  defp kept_hops(trip, shift_s) do
    trip
    |> CompactSchedule.reduce_hops([], fn hop, kept ->
      departure_s = hop.departure_s - shift_s

      if departure_s >= 0 do
        [%{hop | departure_s: departure_s, arrival_s: hop.arrival_s - shift_s} | kept]
      else
        kept
      end
    end)
    |> Enum.reverse()
  end

  # The first pass: the stops and trips the kept hops use, and each trip's
  # runs, the schedule trips that bear its key, to read again in the second.
  defp name_day(%{offset: offset, shift_s: shift_s} = day, named) do
    for schedule <- day.schedules, trip <- schedule.trips, reduce: named do
      named ->
        case kept_hops(trip, shift_s) do
          [] ->
            named

          hops ->
            stops =
              Enum.reduce(hops, named.stops, fn hop, stops ->
                stops
                |> MapSet.put(elem(schedule.stop_ids, hop.from_index))
                |> MapSet.put(elem(schedule.stop_ids, hop.to_index))
              end)

            run = %{schedule: schedule, trip: trip, shift_s: shift_s}

            %{
              stops: stops,
              trips: MapSet.put(named.trips, {offset, trip.id, schedule.route_id}),
              runs: Map.update(named.runs, {offset, trip.id}, [run], &[run | &1])
            }
        end
    end
  end

  # The second pass: every connection record, trip by trip in index order,
  # and within a trip by sequence, then stops and flags, the order the
  # connections keep among themselves where departure and arrival tie. Also
  # the range of departures and durations the records span.
  defp trip_records(%{runs: runs, trip_index: trip_index, stop_index: stop_index}) do
    initial = %{body: <<>>, count: 0, departure_s_max: 0, duration_s_min: 0, duration_s_max: 0}

    for {trip_key, index} <- Enum.sort_by(trip_index, &elem(&1, 1)),
        connection <- trip_connections(Map.fetch!(runs, trip_key), index, stop_index),
        reduce: initial do
      records ->
        duration_s = connection.arrival_s - connection.departure_s

        %{
          body: records.body <> SnapshotFormat.encode_connection(connection),
          count: records.count + 1,
          departure_s_max: max(records.departure_s_max, connection.departure_s),
          duration_s_min: min(records.duration_s_min, duration_s),
          duration_s_max: max(records.duration_s_max, duration_s)
        }
    end
  end

  defp trip_connections(runs, trip, stop_index) do
    connections =
      for %{schedule: schedule, trip: schedule_trip, shift_s: shift_s} <- runs,
          hop <- kept_hops(schedule_trip, shift_s) do
        %{
          departure_s: hop.departure_s,
          arrival_s: hop.arrival_s,
          departure_stop: Map.fetch!(stop_index, elem(schedule.stop_ids, hop.from_index)),
          arrival_stop: Map.fetch!(stop_index, elem(schedule.stop_ids, hop.to_index)),
          trip: trip,
          sequence: hop.sequence,
          boarding: hop.boarding,
          alighting: hop.alighting
        }
      end

    Enum.sort_by(
      connections,
      &{&1.sequence, &1.departure_stop, &1.arrival_stop, &1.boarding, &1.alighting}
    )
  end

  # Sorts the records by one non-negative integer each, departure, then
  # duration, then position in `body`. The position orders records whose
  # departure and arrival tie as the second pass wrote them. The ranges come
  # from the records, so the integer of a date of 677,000 connections fits a
  # machine word and the sort holds no object per record.
  defp in_connection_order(%{count: 0}), do: <<>>

  defp in_connection_order(%{body: body, count: count} = records) do
    duration_s_count = records.duration_s_max - records.duration_s_min + 1
    Assert.condition(records.departure_s_max >= 0, "a kept departure is never negative")

    keys =
      for index <- 0..(count - 1)//1 do
        departure_s = SnapshotFormat.connection_departure_s(body, index)
        duration_s = SnapshotFormat.connection_arrival_s(body, index) - departure_s
        (departure_s * duration_s_count + duration_s - records.duration_s_min) * count + index
      end

    sorted = Enum.sort(keys)
    record_bytes = SnapshotFormat.connection_bytes()

    for key <- sorted, into: <<>> do
      binary_part(body, rem(key, count) * record_bytes, record_bytes)
    end
  end
end
