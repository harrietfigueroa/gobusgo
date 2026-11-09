defmodule Gobusgo.Routing.Timetable do
  @ms_per_second 1_000
  @bucket_s 3_600
  @duration_bias 0x80000000
  @key_bytes 24

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
  Connections are ordered by departure, then arrival, trip, sequence,
  departure stop, arrival stop, and flags, the order a connection scan
  reads them in. The calendar is the source's: OneBusAway answers each date
  with the services that run on it, calendar exceptions applied, so every
  trip a schedule holds runs on its date.

  The schedules are read one at a time, so they can be handed over as a
  stream that decodes each when it is reached, and no list of them, or of
  their stop times, hops, or connections, is held. A first pass names the
  stops and trips. A second writes each connection as a #{@key_bytes}-byte
  key that sorts as a binary in connection order, into one binary per
  #{@bucket_s} seconds of departure; each of those is then sorted alone and
  turned into the records of the connections file. Departures order the
  buckets, so the records come out in connection order with no sort over
  the whole date.
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
  day start, and `schedules` must hold at least one.

  Each is enumerated more than once and must give the same schedules each
  time.
  """
  @spec build(%{
          service_date: Date.t(),
          schedules: Enumerable.t(schedule()),
          previous_schedules: Enumerable.t(schedule())
        }) :: t()
  def build(%{service_date: %Date{} = service_date, schedules: schedules} = input) do
    previous_schedules = Map.fetch!(input, :previous_schedules)
    %{start_ms: start_ms, schedule_count: route_count} = day_start(schedules)
    Assert.condition(route_count >= 1, "a timetable needs at least one schedule")
    today = %{schedules: schedules, offset: 0, shift_s: 0}
    previous = previous_day(previous_schedules, start_ms)
    days = [today | previous]

    named = Enum.reduce(days, %{stops: MapSet.new(), trips: MapSet.new()}, &name_day/2)
    stop_ids = Enum.sort(named.stops)
    stop_index = stop_ids |> Enum.with_index() |> Map.new()
    trips = Enum.sort(named.trips)

    trip_index =
      trips
      |> Enum.with_index()
      |> Map.new(fn {{offset, id, _route}, index} -> {{offset, id}, index} end)

    indexes = %{trip_index: trip_index, stop_index: stop_index}
    buckets = Enum.reduce(days, %{}, &bucket_day(&1, &2, indexes))
    connections = in_connection_order(buckets)

    %{
      service_date: service_date,
      service_day_start_ms: start_ms,
      previous_date_included: previous != [],
      route_count: route_count,
      stop_ids: stop_ids,
      trips:
        for {offset, id, route_id} <- trips do
          %{id: id, route_id: route_id, service_day_offset: offset}
        end,
      connections: connections,
      connection_count: div(byte_size(connections), SnapshotFormat.connection_bytes())
    }
  end

  defp previous_day(previous_schedules, start_ms) do
    case day_start(previous_schedules) do
      %{schedule_count: 0} ->
        []

      %{start_ms: previous_start_ms} ->
        shift_s = div(start_ms - previous_start_ms, @ms_per_second)
        Assert.condition(shift_s > 0, "the previous day must start before this one")
        [%{schedules: previous_schedules, offset: 1, shift_s: shift_s}]
    end
  end

  # The day start every schedule names, nil for no schedule, and the count
  # of schedules.
  defp day_start(schedules) do
    initial = %{start_ms: nil, schedule_count: 0}

    Enum.reduce(schedules, initial, fn %{schedule_date_ms: schedule_start_ms}, day ->
      if day.schedule_count >= 1 do
        Assert.condition(
          schedule_start_ms == day.start_ms,
          "every schedule of a date must start at the same time"
        )
      end

      %{start_ms: schedule_start_ms, schedule_count: day.schedule_count + 1}
    end)
  end

  # Reduces the hops of `trip` that depart at or after the start of the
  # snapshot's day, their times moved back by `shift_s`, in sequence order.
  defp reduce_kept_hops(trip, shift_s, acc, fun) do
    CompactSchedule.reduce_hops(trip, acc, fn hop, acc ->
      departure_s = hop.departure_s - shift_s

      if departure_s >= 0 do
        fun.(%{hop | departure_s: departure_s, arrival_s: hop.arrival_s - shift_s}, acc)
      else
        acc
      end
    end)
  end

  # The first pass: the stops and trips the kept hops use.
  defp name_day(day, named) do
    for schedule <- day.schedules, trip <- schedule.trips, reduce: named do
      named -> name_trip(named, schedule, trip, day)
    end
  end

  defp name_trip(named, schedule, trip, %{offset: offset, shift_s: shift_s}) do
    {stops, kept} =
      reduce_kept_hops(trip, shift_s, {named.stops, false}, fn hop, {stops, _kept} ->
        stops =
          stops
          |> MapSet.put(elem(schedule.stop_ids, hop.from_index))
          |> MapSet.put(elem(schedule.stop_ids, hop.to_index))

        {stops, true}
      end)

    if kept do
      trip_key = {offset, trip.id, schedule.route_id}
      %{named | stops: stops, trips: MapSet.put(named.trips, trip_key)}
    else
      named
    end
  end

  # The second pass: each kept hop's sort key, appended to the binary of
  # the bucket of its departure.
  defp bucket_day(%{offset: offset, shift_s: shift_s} = day, buckets, indexes) do
    for schedule <- day.schedules, trip <- schedule.trips, reduce: buckets do
      buckets ->
        trip_index = Map.get(indexes.trip_index, {offset, trip.id})

        reduce_kept_hops(trip, shift_s, buckets, fn hop, buckets ->
          Assert.condition(trip_index != nil, "a trip with a kept hop is named")

          key =
            sort_key(%{
              hop: hop,
              trip: trip_index,
              departure_stop:
                Map.fetch!(indexes.stop_index, elem(schedule.stop_ids, hop.from_index)),
              arrival_stop: Map.fetch!(indexes.stop_index, elem(schedule.stop_ids, hop.to_index))
            })

          bucket = Integer.floor_div(hop.departure_s, @bucket_s)
          Map.update(buckets, bucket, key, &append_key(&1, key))
        end)
    end
  end

  defp append_key(bucket, key), do: bucket <> key

  # Every field of the record, in the order connections are sorted by, as
  # unsigned big-endian integers, so comparing two keys as binaries compares
  # the connections. The duration is biased into the unsigned range. Two
  # connections whose keys are equal have equal records, so their order
  # among themselves changes no byte of the file.
  defp sort_key(%{hop: hop} = connection) do
    duration_s = hop.arrival_s - hop.departure_s
    Assert.condition(hop.departure_s >= 0, "a kept departure is never negative")

    <<hop.departure_s::32, duration_s + @duration_bias::32, connection.trip::32, hop.sequence::16,
      connection.departure_stop::32, connection.arrival_stop::32, flag(hop.boarding)::8,
      flag(hop.alighting)::8>>
  end

  defp flag(true), do: 1
  defp flag(false), do: 0

  # The records of every bucket, each sorted alone, in bucket order.
  defp in_connection_order(buckets) do
    records =
      for bucket <- buckets |> Map.keys() |> Enum.sort() do
        buckets |> Map.fetch!(bucket) |> bucket_records()
      end

    IO.iodata_to_binary(records)
  end

  defp bucket_records(bucket) do
    Assert.condition(rem(byte_size(bucket), @key_bytes) == 0, "a bucket holds whole keys")
    keys = for <<key::binary-size(@key_bytes) <- bucket>>, do: key
    sorted = Enum.sort(keys)
    for key <- sorted, into: <<>>, do: record(key)
  end

  defp record(
         <<departure_s::32, biased_duration_s::32, trip::32, sequence::16, departure_stop::32,
           arrival_stop::32, boarding::8, alighting::8>>
       ) do
    SnapshotFormat.encode_connection(%{
      departure_s: departure_s,
      arrival_s: departure_s + biased_duration_s - @duration_bias,
      departure_stop: departure_stop,
      arrival_stop: arrival_stop,
      trip: trip,
      sequence: sequence,
      boarding: boarding == 1,
      alighting: alighting == 1
    })
  end
end
