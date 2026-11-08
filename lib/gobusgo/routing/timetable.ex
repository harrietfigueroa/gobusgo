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
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.CompactSchedule
  alias Gobusgo.Routing.SnapshotFormat

  @type schedule :: CompactSchedule.t()

  @type t :: %{
          service_date: Date.t(),
          service_day_start_ms: integer(),
          previous_date_included: boolean(),
          route_count: non_neg_integer(),
          stop_ids: [String.t()],
          trips: [SnapshotFormat.trip()],
          connections: [SnapshotFormat.connection()]
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

    previous =
      case previous_schedules do
        [] ->
          []

        _schedules ->
          shift_s = div(start_ms - day_start_ms(previous_schedules), @ms_per_second)
          Assert.condition(shift_s > 0, "the previous day must start before this one")
          hops(previous_schedules, %{offset: 1, shift_s: shift_s})
      end

    hops = hops(schedules, %{offset: 0, shift_s: 0}) ++ previous

    stop_ids =
      hops
      |> Enum.flat_map(&[&1.departure_stop_id, &1.arrival_stop_id])
      |> Enum.uniq()
      |> Enum.sort()

    stop_index = stop_ids |> Enum.with_index() |> Map.new()
    trips = hops |> Enum.map(&{&1.offset, &1.trip_id, &1.route_id}) |> Enum.uniq() |> Enum.sort()

    trip_index =
      trips
      |> Enum.with_index()
      |> Map.new(fn {{offset, id, _route}, index} -> {{offset, id}, index} end)

    connections =
      hops
      |> Enum.map(&connection(&1, stop_index, trip_index))
      |> Enum.sort_by(&{&1.departure_s, &1.arrival_s, &1.trip, &1.sequence})

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
      connections: connections
    }
  end

  defp day_start_ms([%{schedule_date_ms: start_ms} | _rest] = schedules) do
    Assert.condition(
      Enum.all?(schedules, &(&1.schedule_date_ms == start_ms)),
      "every schedule of a date must start at the same time"
    )

    start_ms
  end

  # Every hop of every trip, its times moved back by `shift_s`, keeping
  # those that depart at or after the start of the snapshot's day.
  defp hops(schedules, %{offset: offset, shift_s: shift_s}) do
    for schedule <- schedules,
        trip <- schedule.trips,
        stop_times = CompactSchedule.stop_times(schedule, trip),
        {{from, to}, sequence} <- stop_times |> Enum.zip(tl(stop_times)) |> Enum.with_index(),
        from.departure_s - shift_s >= 0 do
      %{
        offset: offset,
        trip_id: trip.id,
        route_id: schedule.route_id,
        sequence: sequence,
        departure_stop_id: from.stop_id,
        arrival_stop_id: to.stop_id,
        departure_s: from.departure_s - shift_s,
        arrival_s: to.arrival_s - shift_s,
        boarding: from.departure_enabled,
        alighting: to.arrival_enabled
      }
    end
  end

  defp connection(hop, stop_index, trip_index) do
    %{
      departure_s: hop.departure_s,
      arrival_s: hop.arrival_s,
      departure_stop: Map.fetch!(stop_index, hop.departure_stop_id),
      arrival_stop: Map.fetch!(stop_index, hop.arrival_stop_id),
      trip: Map.fetch!(trip_index, {hop.offset, hop.trip_id}),
      sequence: hop.sequence,
      boarding: hop.boarding,
      alighting: hop.alighting
    }
  end
end
