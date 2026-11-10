defmodule Gobusgo.OneBusAway.TripPath do
  @stop_reach_m 45
  @stretch_ratio_max 2.5
  @stretch_slack_m 150
  @trip_count_max 100
  @polyline_count_max 2_000
  @stop_time_count_max 500
  @coordinate_precision 100_000

  @moduledoc """
  A trip's path on one service date, built from its route's polylines, its
  stops' positions, and its stop times, with no request of its own.
  Everything here is pure.

  The route's polylines hold both directions and every variant of the route
  together, in disconnected pieces, so the path is matched stop pair by
  stop pair. For each two consecutive stops of the trip it takes the
  shortest stretch of any one polyline that passes within
  #{@stop_reach_m} m of the first stop and then, further along, within
  #{@stop_reach_m} m of the second, and that is no longer than
  #{@stretch_ratio_max} times the straight distance between them plus
  #{@stretch_slack_m} m. Where no stretch fits, the pair is joined by a
  straight line between the two stops. Requiring the second stop further
  along than the first keeps a road the route runs both ways to the
  direction the trip travels, and lets a loop's last stop, at its first
  stop's position, land at the end of the polyline rather than its start.

  A stretch starts where the first stop meets its polyline, at the point
  of the polyline nearest the stop within a run of the polyline that passes
  within reach. A stop's distance along the path is where the stretch into
  it ends, so the distances never decrease, the first stop is at 0, and the
  last stop is at the path's end.

  The points are rounded to the five decimal places of the encoded polyline
  format, and a distance is the sum of haversine distances between
  consecutive rounded points on a sphere of radius
  #{Gobusgo.Math.Geodesy.earth_radius_meters()} m,
  rounded to whole meters, so a reader that decodes the points and measures
  them the same way finds each stop where its distance says.

  The matching follows the prototype measured in GOB-238, in which 98.4%
  of 37,910 King County Metro stop pairs matched a polyline.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Math.Geodesy
  alias Gobusgo.Polyline

  @typedoc "A position, latitude then longitude, in degrees."
  @type position :: {number(), number()}

  @typedoc "One stop time of a trip, as `Gobusgo.OneBusAway.CompactSchedule.stop_times/2` returns it."
  @type stop_time :: %{
          required(:stop_id) => String.t(),
          required(:arrival_s) => non_neg_integer(),
          required(:departure_s) => non_neg_integer(),
          optional(atom()) => term()
        }

  @typedoc """
  A trip's path, encoded as it is built, so a build of many trips holds
  each trip's points only while it builds that trip:

    * `points`: in the encoded polyline format, from the first stop to the
      last.
    * `stops`: three numbers per stop, in the order the trip serves them,
      in the same format's number encoding: the distance since the stop
      before in meters, the arrival since the stop before's arrival in
      seconds, and the departure after the arrival in seconds, the first
      stop's taken from zero. Times count from the start of the service
      day.
    * `length_m`: the distance along the points from the first to the last.
    * `matched_pair_count` and `straight_pair_count`: the stop pairs joined
      by a stretch of a polyline and by a straight line.
  """
  @type t :: %{
          points: String.t(),
          stops: String.t(),
          length_m: non_neg_integer(),
          matched_pair_count: non_neg_integer(),
          straight_pair_count: non_neg_integer()
        }

  @typedoc "A path decoded: its points, and each stop's distance along them and times."
  @type decoded :: %{
          points: [Polyline.point()],
          stop_distances_m: [integer()],
          arrival_s: [integer()],
          departure_s: [integer()]
        }

  @typedoc """
    * `:stop_positions_missing`: a stop of the trip has no position.
  """
  @type error :: :stop_positions_missing

  @typedoc """
  The paths of a route's trips, by trip identifier, and the count of
  polylines passed over because they do not decode or hold fewer than two
  distinct points.
  """
  @type route_paths :: %{
          paths: %{String.t() => {:ok, t()} | {:error, error()}},
          polyline_skipped_count: non_neg_integer()
        }

  @doc """
  Returns the path of each of `input.trips`, at most #{@trip_count_max}
  trips of one route with at most #{@stop_time_count_max} stop times each,
  over `input.polylines`, at most #{@polyline_count_max} lines in the
  encoded polyline format, and `input.stop_positions`, each stop's
  position by stop identifier. A trip any of whose stops has no position
  has no path.
  """
  @spec build_route(%{
          polylines: [String.t()],
          stop_positions: %{String.t() => position()},
          trips: [%{id: String.t(), stop_times: [stop_time()]}]
        }) :: route_paths()
  def build_route(%{polylines: polylines, stop_positions: stop_positions, trips: trips})
      when is_list(polylines) and is_map(stop_positions) and is_list(trips) do
    trip_count = length(trips)
    polyline_count = length(polylines)

    Assert.condition(
      trip_count <= @trip_count_max,
      "trip count must be at most #{@trip_count_max}, got: #{trip_count}"
    )

    Assert.condition(
      polyline_count <= @polyline_count_max,
      "polyline count must be at most #{@polyline_count_max}, got: #{polyline_count}"
    )

    decoded = for encoded <- polylines, {:ok, points} = Polyline.decode(encoded), do: points
    projection = projection(decoded)
    lines = decoded |> Enum.map(&line(&1, projection)) |> Enum.reject(&(&1 == :skipped))
    polyline_skipped_count = polyline_count - length(lines)
    lines = List.to_tuple(lines)

    {paths, _passes} =
      Enum.reduce(trips, {%{}, %{}}, fn %{id: trip_id} = trip, {paths, passes} ->
        {outcome, passes} =
          trip_path(%{
            trip: trip,
            lines: lines,
            stop_positions: stop_positions,
            projection: projection,
            passes: passes
          })

        {Map.put(paths, trip_id, outcome), passes}
      end)

    %{paths: paths, polyline_skipped_count: polyline_skipped_count}
  end

  @doc "Returns the points and the stops' distances and times of `path`."
  @spec decode(%{points: String.t(), stops: String.t()}) :: decoded()
  def decode(%{points: points, stops: stops}) when is_binary(points) and is_binary(stops) do
    {:ok, decoded_points} = Polyline.decode(points)
    {:ok, numbers} = Polyline.decode_integers(stops)
    Assert.condition(rem(length(numbers), 3) == 0, "stops hold three numbers per stop")

    {stop_columns, _before} =
      numbers
      |> Enum.chunk_every(3)
      |> Enum.map_reduce({0, 0}, &decode_stop/2)

    %{
      points: decoded_points,
      stop_distances_m: Enum.map(stop_columns, &elem(&1, 0)),
      arrival_s: Enum.map(stop_columns, &elem(&1, 1)),
      departure_s: Enum.map(stop_columns, &elem(&1, 2))
    }
  end

  defp decode_stop(
         [distance_step_m, arrival_step_s, dwell_s],
         {distance_m_before, arrival_s_before}
       ) do
    distance_m = distance_m_before + distance_step_m
    arrival_s = arrival_s_before + arrival_step_s
    {{distance_m, arrival_s, arrival_s + dwell_s}, {distance_m, arrival_s}}
  end

  defp encode(%{points: points} = path) do
    Assert.condition(points != [], "a path has at least one point")

    columns =
      Enum.zip([path.stop_distances_m, path.arrival_s, path.departure_s])

    {numbers, _before} =
      Enum.flat_map_reduce(columns, {0, 0}, fn {distance_m, arrival_s, departure_s},
                                               {distance_m_before, arrival_s_before} ->
        Assert.condition(departure_s >= arrival_s, "a stop departs at or after its arrival")

        {[distance_m - distance_m_before, arrival_s - arrival_s_before, departure_s - arrival_s],
         {distance_m, arrival_s}}
      end)

    %{
      points: Polyline.encode(points),
      stops: Polyline.encode_integers(numbers),
      length_m: path.length_m,
      matched_pair_count: path.matched_pair_count,
      straight_pair_count: path.straight_pair_count
    }
  end

  # The plane the matching measures in: degrees scaled to meters at one
  # latitude, the first point of the route's first polyline, so a route's
  # paths are the same whichever trips are built together. A route's extent
  # of under a degree of latitude keeps the plane within 2% of true
  # distance. A route with no polyline matches nothing, whatever the plane.
  defp projection(decoded) do
    reference_latitude =
      case decoded do
        [[[_longitude, latitude] | _points] | _lines] -> latitude
        _no_point -> 0.0
      end

    meters_per_degree = Geodesy.meters_per_degree()

    %{
      x_scale: meters_per_degree * :math.cos(Geodesy.radians(reference_latitude)),
      y_scale: meters_per_degree
    }
  end

  defp to_plane({latitude, longitude}, %{x_scale: x_scale, y_scale: y_scale}) do
    {longitude * x_scale, latitude * y_scale}
  end

  defp from_plane({x, y}, %{x_scale: x_scale, y_scale: y_scale}) do
    {y / y_scale, x / x_scale}
  end

  # A polyline in the plane: its points and the distance along it at each,
  # as tuples, and the box around it.
  defp line(decoded, projection) do
    points =
      decoded
      |> Enum.map(fn [longitude, latitude] -> to_plane({latitude, longitude}, projection) end)
      |> Enum.dedup()

    case points do
      [_first, _second | _rest] -> plane_line(points)
      _short -> :skipped
    end
  end

  defp plane_line([first | _rest] = points) do
    {cumulative, _last} =
      Enum.map_reduce(points, {first, 0.0}, fn point, {point_before, distance_before} ->
        distance = distance_before + plane_distance(point_before, point)
        {distance, {point, distance}}
      end)

    xs = Enum.map(points, &elem(&1, 0))
    ys = Enum.map(points, &elem(&1, 1))

    %{
      points: List.to_tuple(points),
      cumulative: List.to_tuple(cumulative),
      box: {Enum.min(xs), Enum.min(ys), Enum.max(xs), Enum.max(ys)}
    }
  end

  defp plane_distance({x_a, y_a}, {x_b, y_b}), do: :math.sqrt((x_b - x_a) ** 2 + (y_b - y_a) ** 2)

  defp trip_path(%{trip: %{stop_times: stop_times}, stop_positions: stop_positions} = input) do
    stop_time_count = length(stop_times)
    Assert.condition(stop_time_count > 0, "a trip has at least one stop time")

    Assert.condition(
      stop_time_count <= @stop_time_count_max,
      "a trip has at most #{@stop_time_count_max} stop times, got: #{stop_time_count}"
    )

    stop_ids = Enum.map(stop_times, & &1.stop_id)
    positioned = Enum.all?(stop_ids, &Map.has_key?(stop_positions, &1))

    case positioned do
      true ->
        {path, passes} = positioned_trip_path(%{input | trip: stop_ids})

        times = %{
          arrival_s: Enum.map(stop_times, & &1.arrival_s),
          departure_s: Enum.map(stop_times, & &1.departure_s)
        }

        {{:ok, encode(Map.merge(path, times))}, passes}

      false ->
        {{:error, :stop_positions_missing}, input.passes}
    end
  end

  defp positioned_trip_path(%{trip: [first_stop_id | _rest] = stop_ids} = input) do
    initial = %{
      reversed_points: [],
      point_count: 0,
      reversed_stop_indexes: [0],
      matched_pair_count: 0,
      straight_pair_count: 0,
      passes: input.passes
    }

    assembled =
      stop_ids
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.reduce(initial, fn [stop_id_a, stop_id_b], assembled ->
        append_pair(assembled, %{input | trip: {stop_id_a, stop_id_b}})
      end)

    # A trip of one stop has no pair, and its path is the stop alone.
    points =
      case assembled.reversed_points do
        [] -> [input.stop_positions |> Map.fetch!(first_stop_id) |> rounded_point()]
        reversed_points -> Enum.reverse(reversed_points)
      end

    cumulative = cumulative_m(points)

    stop_distances_m =
      assembled.reversed_stop_indexes
      |> Enum.reverse()
      |> Enum.map(&round(elem(cumulative, &1)))

    path = %{
      points:
        Enum.map(points, fn {latitude_e5, longitude_e5} ->
          [longitude_e5 / @coordinate_precision, latitude_e5 / @coordinate_precision]
        end),
      stop_distances_m: stop_distances_m,
      length_m: round(elem(cumulative, tuple_size(cumulative) - 1)),
      matched_pair_count: assembled.matched_pair_count,
      straight_pair_count: assembled.straight_pair_count
    }

    {path, assembled.passes}
  end

  # Appends the stretch from one stop to the next, and notes where the
  # second stop falls among the points. A stretch after the first starts
  # from its second point, joining the end of the stretch before, which
  # lies within reach of the same stop.
  defp append_pair(assembled, %{trip: {stop_id_a, stop_id_b}} = input) do
    position_a = Map.fetch!(input.stop_positions, stop_id_a)
    position_b = Map.fetch!(input.stop_positions, stop_id_b)
    passes = stop_passes(assembled.passes, %{input | trip: stop_id_a})
    passes = stop_passes(passes, %{input | trip: stop_id_b})

    stretch =
      shortest_stretch(%{
        lines: input.lines,
        passes_a: Map.fetch!(passes, stop_id_a),
        passes_b: Map.fetch!(passes, stop_id_b),
        length_m_max:
          @stretch_ratio_max *
            plane_distance(
              to_plane(position_a, input.projection),
              to_plane(position_b, input.projection)
            ) +
            @stretch_slack_m
      })

    {stretch_points, counts} =
      case stretch do
        nil ->
          {[rounded_point(position_a), rounded_point(position_b)],
           %{assembled | straight_pair_count: assembled.straight_pair_count + 1}}

        {line_index, start_m, end_m} ->
          rounded =
            input.lines
            |> elem(line_index)
            |> stretch_points(start_m, end_m)
            |> Enum.map(&(&1 |> from_plane(input.projection) |> rounded_point()))

          {rounded, %{assembled | matched_pair_count: assembled.matched_pair_count + 1}}
      end

    joined_points =
      case counts.reversed_points do
        [] -> stretch_points
        _assembled -> tl(stretch_points)
      end

    {reversed_points, point_count} =
      Enum.reduce(joined_points, {counts.reversed_points, counts.point_count}, &push_distinct/2)

    %{
      counts
      | reversed_points: reversed_points,
        point_count: point_count,
        reversed_stop_indexes: [point_count - 1 | counts.reversed_stop_indexes],
        passes: passes
    }
  end

  # Rounding can make two neighboring points one, which is kept once.
  defp push_distinct(point, {[point | _rest] = reversed, count}), do: {reversed, count}
  defp push_distinct(point, {reversed, count}), do: {[point | reversed], count + 1}

  # The places each line passes within reach of a stop, computed once per
  # stop and kept for the route's other pairs and trips.
  defp stop_passes(passes, %{trip: stop_id} = input) do
    case Map.has_key?(passes, stop_id) do
      true ->
        passes

      false ->
        point = input.stop_positions |> Map.fetch!(stop_id) |> to_plane(input.projection)
        Map.put(passes, stop_id, line_passes(input.lines, point))
    end
  end

  # Each pass is `{line index, distance along the line}`: one per run of
  # consecutive segments within reach of the point, at the run's point
  # nearest it.
  defp line_passes(lines, point) do
    for line_index <- 0..(tuple_size(lines) - 1)//1,
        line = elem(lines, line_index),
        within_box?(line.box, point),
        along_m <- runs(line, point),
        do: {line_index, along_m}
  end

  defp within_box?({x_min, y_min, x_max, y_max}, {x, y}) do
    x >= x_min - @stop_reach_m and x <= x_max + @stop_reach_m and y >= y_min - @stop_reach_m and
      y <= y_max + @stop_reach_m
  end

  defp runs(%{points: points} = line, point) do
    segment_count = tuple_size(points) - 1
    scan_runs(%{line: line, point: point, segment_count: segment_count}, 0, {[], nil})
  end

  # Walks the segments in order, the index rising by one each step up to
  # the line's segment count, keeping the open run's nearest projection.
  defp scan_runs(%{segment_count: segment_count}, segment_count, {runs, open_run}) do
    case open_run do
      nil -> Enum.reverse(runs)
      {_nearest_m, along_m} -> Enum.reverse([along_m | runs])
    end
  end

  defp scan_runs(scan, segment_index, {runs, open_run}) do
    projection = segment_projection(scan.line, segment_index, scan.point)

    next =
      case {projection, open_run} do
        {:beyond, nil} ->
          {runs, nil}

        {:beyond, {_nearest_m, along_m}} ->
          {[along_m | runs], nil}

        {nearest, nil} ->
          {runs, nearest}

        {{distance_m, _along_m} = nearest, {kept_m, _kept}} when distance_m < kept_m ->
          {runs, nearest}

        {_farther, kept} ->
          {runs, kept}
      end

    scan_runs(scan, segment_index + 1, next)
  end

  # The point of a segment nearest `{x, y}`, as its distance and its
  # distance along the line, or `:beyond` for a segment out of reach. A
  # segment whose box, widened by the reach, leaves the point out is out of
  # reach without a projection, which is most of a line's segments.
  defp segment_projection(%{points: points, cumulative: cumulative}, segment_index, {x, y}) do
    {x_a, y_a} = elem(points, segment_index)
    {x_b, y_b} = elem(points, segment_index + 1)

    outside_x = x < min(x_a, x_b) - @stop_reach_m or x > max(x_a, x_b) + @stop_reach_m
    outside_y = y < min(y_a, y_b) - @stop_reach_m or y > max(y_a, y_b) + @stop_reach_m
    outside_box = outside_x or outside_y

    case outside_box do
      true ->
        :beyond

      false ->
        nearest_on_segment(
          %{a: {x_a, y_a}, b: {x_b, y_b}, start_m: elem(cumulative, segment_index)},
          {x, y}
        )
    end
  end

  defp nearest_on_segment(%{a: {x_a, y_a}, b: {x_b, y_b}, start_m: start_m}, {x, y}) do
    {dx, dy} = {x_b - x_a, y_b - y_a}
    length_squared = dx * dx + dy * dy
    fraction = max(0.0, min(1.0, ((x - x_a) * dx + (y - y_a) * dy) / length_squared))
    nearest = {x_a + fraction * dx, y_a + fraction * dy}
    distance_m = plane_distance(nearest, {x, y})

    case distance_m < @stop_reach_m do
      true -> {distance_m, start_m + fraction * :math.sqrt(length_squared)}
      false -> :beyond
    end
  end

  # The shortest stretch of one line from a pass of the first stop to a
  # later pass of the second, within the length bound, as
  # `{line index, start, end}`, or `nil` where there is none.
  defp shortest_stretch(%{passes_a: passes_a, passes_b: passes_b, length_m_max: length_m_max}) do
    candidates =
      for {line_index, start_m} <- passes_a,
          {^line_index, end_m} <- passes_b,
          end_m > start_m,
          end_m - start_m <= length_m_max,
          do: {end_m - start_m, line_index, start_m, end_m}

    case candidates do
      [] ->
        nil

      _found ->
        {_length, line_index, start_m, end_m} = Enum.min(candidates)
        {line_index, start_m, end_m}
    end
  end

  # The points of a line from `start_m` to `end_m` along it: the point at
  # each end and the line's own points between.
  defp stretch_points(%{points: points, cumulative: cumulative} = line, start_m, end_m) do
    start_index = segment_at(cumulative, start_m)
    end_index = segment_at(cumulative, end_m)

    between =
      for index <- (start_index + 1)..end_index//1,
          along_m = elem(cumulative, index),
          along_m > start_m and along_m < end_m,
          do: elem(points, index)

    [point_at(line, start_index, start_m)] ++ between ++ [point_at(line, end_index, end_m)]
  end

  # The index of the segment that holds `along_m`: the last point at or
  # before it, and never the line's last point, found by halving.
  defp segment_at(cumulative, along_m) do
    halve(cumulative, along_m, 0, tuple_size(cumulative) - 2)
  end

  defp halve(_cumulative, _along_m, low, high) when low >= high, do: low

  defp halve(cumulative, along_m, low, high) do
    middle = div(low + high + 1, 2)

    case elem(cumulative, middle) <= along_m do
      true -> halve(cumulative, along_m, middle, high)
      false -> halve(cumulative, along_m, low, middle - 1)
    end
  end

  defp point_at(%{points: points, cumulative: cumulative}, segment_index, along_m) do
    {x_a, y_a} = elem(points, segment_index)
    {x_b, y_b} = elem(points, segment_index + 1)
    start_m = elem(cumulative, segment_index)
    segment_m = elem(cumulative, segment_index + 1) - start_m
    fraction = max(0.0, min(1.0, (along_m - start_m) / segment_m))
    {x_a + fraction * (x_b - x_a), y_a + fraction * (y_b - y_a)}
  end

  defp rounded_point({latitude, longitude}) do
    {round(latitude * @coordinate_precision), round(longitude * @coordinate_precision)}
  end

  defp cumulative_m([first | _rest] = points) do
    {cumulative, _last} =
      Enum.map_reduce(points, {first, 0.0}, fn point, {point_before, distance_before} ->
        distance = distance_before + rounded_distance_m(point_before, point)
        {distance, {point, distance}}
      end)

    List.to_tuple(cumulative)
  end

  defp rounded_distance_m(point_a, point_b) do
    Geodesy.distance_meters(rounded_position(point_a), rounded_position(point_b))
  end

  defp rounded_position({latitude_e5, longitude_e5}) do
    %{lat: latitude_e5 / @coordinate_precision, lon: longitude_e5 / @coordinate_precision}
  end
end
