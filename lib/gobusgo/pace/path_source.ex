defmodule Gobusgo.Pace.PathSource do
  @moduledoc """
  The path of a vehicle's trip, prepared for `Gobusgo.Pace.Learning`, from
  what the route path view, the stop view, and the route schedule view hold,
  as `Gobusgo.OneBusAway.TripPath` builds it. `build/1` is pure; `fetch/2`
  reads the views and makes no request of any source.
  """

  alias Gobusgo.OneBusAway.CompactSchedule
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteScheduleView
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.OneBusAway.TripPath
  alias Gobusgo.Pace.Learning

  @type views :: %{schedule_view: atom(), route_path_view: atom(), stop_view: atom()}

  @doc """
  Reads the views for the path of `trip.trip_id` of `trip.route_id` on the
  service date that begins at `trip.service_date_ms`, or `:unavailable` where
  a view lacks the schedule, the route's path, or a stop's position.
  """
  @spec fetch(
          %{route_id: String.t(), trip_id: String.t(), service_date_ms: non_neg_integer()},
          views()
        ) ::
          {:ok, Learning.path()} | :unavailable
  def fetch(%{route_id: route_id, trip_id: trip_id, service_date_ms: service_date_ms}, views) do
    service_date = service_date_ms |> DateTime.from_unix!(:millisecond) |> DateTime.to_date()
    schedule = RouteScheduleView.schedule(views.schedule_view, route_id, service_date)
    route_path = FetchView.current_fetch(views.route_path_view, route_id)

    case {schedule, route_path} do
      {%{schedule: schedule}, %{} = route_path} ->
        fetch_trip(%{schedule: schedule, route_path: route_path, trip_id: trip_id}, views)

      {_schedule, _route_path} ->
        :unavailable
    end
  end

  defp fetch_trip(%{schedule: schedule, route_path: route_path, trip_id: trip_id}, views) do
    case Enum.find(schedule.trips, &(&1.id == trip_id)) do
      nil ->
        :unavailable

      trip ->
        stop_times = CompactSchedule.stop_times(schedule, trip)

        build(%{
          polylines: polylines(route_path),
          stop_positions: stop_positions(stop_times, views.stop_view),
          trip: %{id: trip_id, stop_times: stop_times}
        })
    end
  end

  @doc """
  The prepared path of `input.trip`, from `input.polylines` in the encoded
  polyline format and `input.stop_positions`, each stop's `{lat, lon}`, or
  `:unavailable` where the trip has no path or no stop time.
  """
  @spec build(%{
          polylines: [String.t()],
          stop_positions: %{String.t() => TripPath.position()},
          trip: %{id: String.t(), stop_times: [TripPath.stop_time()]}
        }) :: {:ok, Learning.path()} | :unavailable
  def build(%{trip: %{stop_times: [first_stop | _rest]}} = input) do
    %{trip: %{id: trip_id}} = input

    built =
      TripPath.build_route(%{
        polylines: input.polylines,
        stop_positions: input.stop_positions,
        trips: [input.trip]
      })

    case built.paths do
      %{^trip_id => {:ok, encoded}} ->
        %{points: points} = TripPath.decode(encoded)

        {:ok,
         Learning.prepare_path(%{points: points, band: Learning.band(first_stop.departure_s)})}

      %{} ->
        :unavailable
    end
  end

  def build(%{trip: %{stop_times: []}}), do: :unavailable

  defp polylines(route_path) do
    group_polylines =
      for grouping <- route_path.stop_groupings,
          group <- grouping["stopGroups"],
          polyline <- group["polylines"],
          do: polyline["points"]

    Enum.map(route_path.polylines, & &1["points"]) ++ group_polylines
  end

  defp stop_positions(stop_times, stop_view) do
    for stop_time <- stop_times,
        held = StopView.stop(stop_view, stop_time.stop_id),
        held != nil,
        into: %{},
        do: {stop_time.stop_id, {held.stop["lat"], held.stop["lon"]}}
  end
end
