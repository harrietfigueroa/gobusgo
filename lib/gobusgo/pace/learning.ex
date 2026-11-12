defmodule Gobusgo.Pace.Learning do
  @step_m 10
  @gap_s_max 90
  @off_path_m_max 60
  @speed_mps_max 30
  @backward_slack_m 1
  @cell_lon_degrees 0.00045
  @cell_lat_degrees 0.0003
  @direction_count 8
  @degrees_per_turn 360
  @ms_per_second 1000

  @moduledoc """
  What the pace table learns from vehicle reports. Everything here is pure.

  The idea of historical travel times per fixed-length segment is
  TheTransitClock's, adapted here and keyed by place instead of by trip
  (GPL-3.0-or-later; ideas only, no code copied).
  https://github.com/TheTransitClock/transitime/blob/dee0402/transitclock/src/main/java/org/transitclock/core/travelTimes/TravelTimesProcessor.java — checked 2026-11-12

  A vehicle's consecutive reports on one trip, at most #{@gap_s_max} s
  apart, are each projected onto the trip's path, the later one no earlier
  than #{@backward_slack_m} m before the earlier, and a report more than
  #{@off_path_m_max} m from the path is dropped. A pair is usable when its
  seconds are positive and at most #{@gap_s_max}, its meters are not
  negative, and its speed is at most #{@speed_mps_max} m/s. Its seconds are
  spread over the meters it covered in steps of #{@step_m} m along the path,
  each step taking the seconds of its share of the meters and the meters
  themselves. A pair whose two positions fall in one step, a stand
  included, gives that step all its seconds and meters.

  A step's cell is the path position at the step's start, floored into a
  grid of #{@cell_lon_degrees} degrees of longitude by #{@cell_lat_degrees}
  degrees of latitude, with the direction of travel, the initial bearing of
  the path segment at that position in #{@direction_count} buckets of
  #{div(@degrees_per_turn, @direction_count)} degrees centered on north.
  One table covers every hour of the day.
  """

  alias Gobusgo.Math.Geodesy

  @typedoc "A cell of the table: grid longitude, grid latitude, direction."
  @type key :: {integer(), integer(), 0..7}

  @typedoc "One vehicle report: where a vehicle was, on which trip, and when."
  @type report :: %{
          vehicle_key: {String.t(), String.t()},
          trip_key: {String.t(), non_neg_integer()},
          route_id: String.t(),
          position: %{lon: float(), lat: float()},
          at_ms: pos_integer()
        }

  @typedoc "Where a report put its vehicle along its trip's path."
  @type placed :: %{
          trip_key: {String.t(), non_neg_integer()},
          meters: float(),
          at_ms: pos_integer()
        }

  @typedoc "A trip's path prepared for projection: tuples of per-point values."
  @type path :: %{
          lons: tuple(),
          lats: tuple(),
          xs: tuple(),
          ys: tuple(),
          cumulative: tuple(),
          length_m: float(),
          meters_per_degree_lon: float()
        }

  @doc """
  Whether a vehicle placed at `placed` can no longer pair with a report made
  at `now_ms`, a gap longer than the pair bound later.
  """
  @spec stale?(placed(), integer()) :: boolean()
  def stale?(%{at_ms: at_ms}, now_ms) when is_integer(now_ms) do
    now_ms - at_ms > @gap_s_max * @ms_per_second
  end

  @doc "The meters of one step along a path."
  @spec step_m() :: pos_integer()
  def step_m, do: @step_m

  @doc "The grid of a cell, as the degrees of longitude and of latitude it spans."
  @spec cell_degrees() :: %{lon: float(), lat: float()}
  def cell_degrees, do: %{lon: @cell_lon_degrees, lat: @cell_lat_degrees}

  @doc "The count of direction buckets."
  @spec direction_count() :: pos_integer()
  def direction_count, do: @direction_count

  @doc """
  The reports of the vehicles of one agency's fetch that name a trip, its
  service date, a route, a location, and a time the vehicle reported it. A
  vehicle with none of them, or whose location time is the source's `0` for
  never, has no report.
  """
  @spec reports(%{agency_id: String.t(), vehicles: [map()]}) :: [report()]
  def reports(%{agency_id: agency_id, vehicles: vehicles}) when is_list(vehicles) do
    for vehicle <- vehicles, {:ok, report} <- [report(agency_id, vehicle)], do: report
  end

  defp report(agency_id, %{
         id: vehicle_id,
         active_trip_id: trip_id,
         route_id: route_id,
         service_date_ms: service_date_ms,
         last_known_location: %{lat: lat, lon: lon},
         last_location_update_time_ms: at_ms
       })
       when is_binary(trip_id) and is_binary(route_id) and is_integer(service_date_ms) and
              is_number(lat) and is_number(lon) and is_integer(at_ms) and at_ms > 0 do
    {:ok,
     %{
       vehicle_key: {agency_id, vehicle_id},
       trip_key: {trip_id, service_date_ms},
       route_id: route_id,
       position: %{lon: lon, lat: lat},
       at_ms: at_ms
     }}
  end

  defp report(_agency_id, _vehicle), do: :skipped

  @doc """
  Prepares `input.points`, a path's `[lon, lat]` points from its first to
  its last, at least two, for projection on the plane tangent at the first
  point's latitude.
  """
  @spec prepare_path(%{points: [[number()]]}) :: path()
  def prepare_path(%{points: [[_lon, first_lat] | _rest] = points})
      when length(points) >= 2 do
    meters_per_degree_lon =
      Geodesy.meters_per_degree() * :math.cos(Geodesy.radians(first_lat))

    cumulative = cumulative(points)
    lons = for [lon, _lat] <- points, do: lon
    lats = for [_lon, lat] <- points, do: lat
    xs = for lon <- lons, do: lon * meters_per_degree_lon
    ys = for lat <- lats, do: lat * Geodesy.meters_per_degree()

    %{
      lons: List.to_tuple(lons),
      lats: List.to_tuple(lats),
      xs: List.to_tuple(xs),
      ys: List.to_tuple(ys),
      cumulative: List.to_tuple(cumulative),
      length_m: List.last(cumulative),
      meters_per_degree_lon: meters_per_degree_lon
    }
  end

  defp cumulative([[first_lon, first_lat] | rest]) do
    {reversed, _last} =
      Enum.reduce(rest, {[0.0], {first_lon, first_lat}}, fn [lon, lat],
                                                            {[along | _] = acc,
                                                             {last_lon, last_lat}} ->
        meters =
          Geodesy.distance_meters(%{lon: last_lon, lat: last_lat}, %{lon: lon, lat: lat})

        {[along + meters | acc], {lon, lat}}
      end)

    Enum.reverse(reversed)
  end

  @doc """
  Where `position` falls along `path`: of the points of each segment nearest
  to it, the nearest at least `along_min` along the path, as its distance
  along the path, or `:off_path` when it is further than
  #{@off_path_m_max} m from the path or no point of the path lies at
  `along_min` or later.
  """
  @spec project(path(), %{lon: number(), lat: number()}, number()) ::
          {:on_path, float()} | :off_path
  def project(%{} = path, %{lon: lon, lat: lat}, along_min) do
    x = lon * path.meters_per_degree_lon
    y = lat * Geodesy.meters_per_degree()
    segment_count = tuple_size(path.xs) - 1

    {offset_best, along_best} =
      Enum.reduce(0..(segment_count - 1)//1, {nil, along_min}, fn index, best ->
        segment_nearest(path, %{index: index, x: x, y: y, along_min: along_min}, best)
      end)

    is_near = offset_best != nil and offset_best <= @off_path_m_max

    if is_near do
      {:on_path, along_best}
    else
      :off_path
    end
  end

  defp segment_nearest(path, %{index: index, x: x, y: y, along_min: along_min}, best) do
    along_start = elem(path.cumulative, index)
    along_end = elem(path.cumulative, index + 1)

    if along_end < along_min do
      best
    else
      source_x = elem(path.xs, index)
      source_y = elem(path.ys, index)
      delta_x = elem(path.xs, index + 1) - source_x
      delta_y = elem(path.ys, index + 1) - source_y
      squared_length = delta_x * delta_x + delta_y * delta_y

      fraction =
        if squared_length > 0 do
          dot = (x - source_x) * delta_x + (y - source_y) * delta_y
          min(1.0, max(0.0, dot / squared_length))
        else
          0.0
        end

      along = along_start + (along_end - along_start) * fraction

      offset =
        :math.sqrt(
          (source_x + fraction * delta_x - x) ** 2 + (source_y + fraction * delta_y - y) ** 2
        )

      {offset_best, _along_best} = best
      is_after_min = along >= along_min
      is_nearer = offset_best == nil or offset < offset_best

      if is_after_min and is_nearer do
        {offset, along}
      else
        best
      end
    end
  end

  @doc """
  The cell of the step of `path` that starts `meters` along it, clamped to
  the path's length.
  """
  @spec cell_key(path(), number()) :: key()
  def cell_key(%{} = path, meters) when is_number(meters) do
    along = min(max(meters, 0), path.length_m)
    index = segment_index(path.cumulative, along, 0, tuple_size(path.cumulative) - 1)
    along_start = elem(path.cumulative, index)
    span = elem(path.cumulative, index + 1) - along_start

    fraction =
      if span > 0 do
        min(1.0, max(0.0, (along - along_start) / span))
      else
        0.0
      end

    source = %{lon: elem(path.lons, index), lat: elem(path.lats, index)}
    target = %{lon: elem(path.lons, index + 1), lat: elem(path.lats, index + 1)}
    lon = source.lon + (target.lon - source.lon) * fraction
    lat = source.lat + (target.lat - source.lat) * fraction
    bearing = Geodesy.initial_bearing_degrees(source, target)
    bucket_width = @degrees_per_turn / @direction_count
    direction = rem(floor(bearing / bucket_width + 0.5), @direction_count)

    {floor(lon / @cell_lon_degrees), floor(lat / @cell_lat_degrees), direction}
  end

  # The last index below `high` whose cumulative distance is at or before
  # `along`, halving the points.
  defp segment_index(_cumulative, _along, low, high) when high - low <= 1, do: low

  defp segment_index(cumulative, along, low, high) do
    middle = div(low + high, 2)

    if elem(cumulative, middle) <= along do
      segment_index(cumulative, along, middle, high)
    else
      segment_index(cumulative, along, low, middle)
    end
  end

  @doc """
  Splits the seconds of a pair that went from `from_m` to `to_m` along its
  path into the steps it overlapped, as `{step index, seconds, meters}`,
  leaving out a step that no meter of the pair covered.
  """
  @spec spread(%{seconds: number(), from_m: number(), to_m: number()}) :: [
          {non_neg_integer(), number(), number()}
        ]
  def spread(%{seconds: seconds, from_m: from_m, to_m: to_m}) when to_m >= from_m do
    first = floor(from_m / @step_m)
    last = floor(to_m / @step_m)
    pair_m = to_m - from_m

    if first == last do
      [{first, seconds, pair_m}]
    else
      for index <- first..last,
          covered = min(to_m, (index + 1) * @step_m) - max(from_m, index * @step_m),
          covered > 0 do
        {index, seconds * covered / pair_m, covered}
      end
    end
  end

  @doc """
  Advances one vehicle by one report. `input.previous` is where the vehicle's
  last report placed it, or `nil`, and `input.path` the path of the report's
  trip, or `nil` where it has none. Returns where the report places the
  vehicle, `nil` where it places it nowhere, and the cells the pair of the
  two reports adds to, as `{key, seconds, meters}`.
  """
  @spec advance(%{previous: placed() | nil, report: report(), path: path() | nil}) :: %{
          placed: placed() | nil,
          cells: [{key(), number(), number()}]
        }
  def advance(%{path: nil}), do: %{placed: nil, cells: []}

  def advance(%{previous: previous, report: report, path: path}) do
    paired = pairable(previous, report.trip_key)

    along_min =
      case paired do
        %{meters: meters} -> meters - @backward_slack_m
        nil -> 0
      end

    case project(path, report.position, along_min) do
      :off_path ->
        %{placed: nil, cells: []}

      {:on_path, meters} ->
        placed = %{trip_key: report.trip_key, meters: meters, at_ms: report.at_ms}
        %{placed: placed, cells: cells(paired, placed, path)}
    end
  end

  defp pairable(%{trip_key: trip_key} = previous, trip_key), do: previous
  defp pairable(_previous, _trip_key), do: nil

  defp cells(nil, _placed, _path), do: []

  defp cells(previous, placed, path) do
    seconds = (placed.at_ms - previous.at_ms) / @ms_per_second
    meters = placed.meters - previous.meters
    is_timed = seconds > 0 and seconds <= @gap_s_max
    is_moving = meters >= 0 and meters <= @speed_mps_max * seconds
    is_usable = is_timed and is_moving

    if is_usable do
      steps = spread(%{seconds: seconds, from_m: previous.meters, to_m: placed.meters})

      for {index, step_seconds, step_meters} <- steps,
          step_seconds > 0 do
        {cell_key(path, index * @step_m), step_seconds, step_meters}
      end
    else
      []
    end
  end
end
