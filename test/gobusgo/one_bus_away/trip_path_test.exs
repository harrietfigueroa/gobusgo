defmodule Gobusgo.OneBusAway.TripPathTest do
  # Verifies the trip path as a pure function of a route's polylines, its
  # stops' positions, and a trip's stop times. The stored fixtures are
  # King County Metro's loop route 1_7994 on 2026-11-09, its route path and
  # two of its trips, built as the views hold them; the cases the stored
  # route does not show, a pair no polyline joins, a detour past the length
  # bound, and a line that runs the wrong way, move one stop or draw a
  # synthetic line, so each case names the one input it changes.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.CompactSchedule
  alias Gobusgo.OneBusAway.RoutePaths
  alias Gobusgo.OneBusAway.RouteSchedules
  alias Gobusgo.OneBusAway.TripPath
  alias Gobusgo.Polyline

  @fixture_directory Path.expand("../../fixtures/one_bus_away/trip_path", __DIR__)
  @route_id "1_7994"
  @trip_id "1_1137791"
  @earth_radius_m 6_371_008.8
  @rounding_m_max 1.5
  @stop_offset_m 200

  defp fixture(name) do
    @fixture_directory |> Path.join(name <> ".json") |> File.read!() |> JSON.decode!()
  end

  defp route_path do
    {:ok, route_path} = RoutePaths.parse(fixture("stops_for_route_loop")["data"], @route_id)
    route_path
  end

  defp polylines(route_path) do
    group_polylines =
      for grouping <- route_path.stop_groupings,
          group <- grouping.stop_groups,
          polyline <- group.polylines,
          do: polyline.points

    Enum.map(route_path.polylines, & &1.points) ++ group_polylines
  end

  defp stop_positions(route_path) do
    Map.new(route_path.stops, &{&1.id, {&1.lat, &1.lon}})
  end

  defp trips do
    {:ok, schedule} = RouteSchedules.parse(fixture("schedule_for_route_loop")["data"], @route_id)
    {:ok, compact} = schedule |> CompactSchedule.list() |> CompactSchedule.pack()

    Enum.map(compact.trips, fn trip ->
      %{id: trip.id, stop_times: CompactSchedule.stop_times(compact, trip)}
    end)
  end

  defp stored_input do
    route_path = route_path()

    %{
      polylines: polylines(route_path),
      stop_positions: stop_positions(route_path),
      trips: trips()
    }
  end

  defp stored_path(input) do
    %{paths: %{@trip_id => {:ok, path}}} = TripPath.build_route(input)
    Map.merge(path, TripPath.decode(path))
  end

  defp first_trip_stop_ids do
    [trip | _trips] = trips()
    Enum.map(trip.stop_times, & &1.stop_id)
  end

  # The haversine distance between two positions, as a reader of the
  # encoded path measures it.
  defp distance_m({latitude_a, longitude_a}, {latitude_b, longitude_b}) do
    latitude_a = latitude_a * :math.pi() / 180
    latitude_b = latitude_b * :math.pi() / 180
    half_latitude = (latitude_b - latitude_a) / 2
    half_longitude = (longitude_b - longitude_a) * :math.pi() / 360

    haversine =
      :math.sin(half_latitude) ** 2 +
        :math.cos(latitude_a) * :math.cos(latitude_b) * :math.sin(half_longitude) ** 2

    2 * @earth_radius_m * :math.asin(min(1.0, :math.sqrt(haversine)))
  end

  # The distance from a point to the nearest of a line's segments, with the
  # segment taken as straight in degrees scaled to meters at its latitude.
  defp distance_to_line_m({latitude, longitude}, line) do
    line
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [[longitude_a, latitude_a], [longitude_b, latitude_b]] ->
      scale = :math.cos(latitude * :math.pi() / 180)
      {ax, ay} = {(longitude_a - longitude) * scale, latitude_a - latitude}
      {bx, by} = {(longitude_b - longitude) * scale, latitude_b - latitude}
      {dx, dy} = {bx - ax, by - ay}
      length_squared = dx * dx + dy * dy

      fraction =
        case length_squared do
          +0.0 -> 0.0
          _positive -> max(0.0, min(1.0, -(ax * dx + ay * dy) / length_squared))
        end

      {cx, cy} = {ax + fraction * dx, ay + fraction * dy}
      :math.sqrt(cx * cx + cy * cy) * @earth_radius_m * :math.pi() / 180
    end)
    |> Enum.min()
  end

  # A position `offset_m` north of `position`.
  defp north_of({latitude, longitude}, offset_m) do
    {latitude + offset_m / (@earth_radius_m * :math.pi() / 180), longitude}
  end

  # A position `offset_m` east of `position`.
  defp east_of({latitude, longitude}, offset_m) do
    scale = :math.cos(latitude * :math.pi() / 180)
    {latitude, longitude + offset_m / (@earth_radius_m * :math.pi() / 180 * scale)}
  end

  defp encoded(positions) do
    positions
    |> Enum.map(fn {latitude, longitude} -> [longitude, latitude] end)
    |> Polyline.encode()
  end

  defp synthetic_trip(stop_ids) do
    stop_times =
      stop_ids
      |> Enum.with_index()
      |> Enum.map(fn {stop_id, index} ->
        %{stop_id: stop_id, arrival_s: 3_600 + index * 60, departure_s: 3_620 + index * 60}
      end)

    %{id: "trip", stop_times: stop_times}
  end

  defp synthetic_path(%{line: line, stop_positions: stop_positions, stop_ids: stop_ids}) do
    input = %{
      polylines: [encoded(line)],
      stop_positions: stop_positions,
      trips: [synthetic_trip(stop_ids)]
    }

    %{paths: %{"trip" => outcome}} = TripPath.build_route(input)

    case outcome do
      {:ok, path} -> {:ok, Map.merge(path, TripPath.decode(path))}
      refused -> refused
    end
  end

  @origin {47.6, -122.33}

  describe "build_route/1 over the stored loop route" do
    test "matches every stop pair to the route's polyline" do
      path = stored_path(stored_input())

      assert path.straight_pair_count == 0
      assert path.matched_pair_count == length(first_trip_stop_ids()) - 1
    end

    test "lays every point of a matched path on the route's polyline" do
      route_path = route_path()
      path = stored_path(stored_input())
      {:ok, line} = route_path.polylines |> hd() |> Map.fetch!(:points) |> Polyline.decode()

      distances_m =
        Enum.map(path.points, fn [longitude, latitude] ->
          distance_to_line_m({latitude, longitude}, line)
        end)

      assert Enum.max(distances_m) < @rounding_m_max
    end

    test "projects the loop's last stop forward onto the path's end, never back onto its start" do
      path = stored_path(stored_input())
      [first_stop_id | _stops] = first_trip_stop_ids()

      assert List.last(first_trip_stop_ids()) == first_stop_id
      assert hd(path.stop_distances_m) == 0
      assert List.last(path.stop_distances_m) == path.length_m
      assert path.length_m > 0
    end

    test "gives each stop a distance at or after the stop before it" do
      distances_m = stored_path(stored_input()).stop_distances_m

      assert distances_m == Enum.sort(distances_m)
      assert length(distances_m) == length(first_trip_stop_ids())
    end

    test "carries each stop's scheduled arrival and departure in the trip's order" do
      [trip | _trips] = trips()
      path = stored_path(stored_input())

      assert path.arrival_s == Enum.map(trip.stop_times, & &1.arrival_s)
      assert path.departure_s == Enum.map(trip.stop_times, & &1.departure_s)
    end

    test "builds a path for every trip it is given" do
      %{paths: paths} = TripPath.build_route(stored_input())

      assert paths |> Map.keys() |> Enum.sort() == ["1_1137791", "1_1137792"]
      assert Enum.all?(Map.values(paths), &match?({:ok, _path}, &1))
    end

    test "builds the same path for a trip whichever trips are built with it" do
      input = stored_input()
      [first_trip | _trips] = input.trips
      %{paths: %{@trip_id => together}} = TripPath.build_route(input)

      %{paths: %{@trip_id => alone}} =
        TripPath.build_route(%{
          input
          | trips: [first_trip],
            stop_positions: Map.take(input.stop_positions, first_trip_stop_ids())
        })

      assert alone == together
    end

    test "draws a straight line to and from a stop no polyline passes within reach of" do
      input = stored_input()
      moved_stop_id = Enum.at(first_trip_stop_ids(), 3)
      moved = north_of(Map.fetch!(input.stop_positions, moved_stop_id), @stop_offset_m)
      moved = east_of(moved, @stop_offset_m)
      input = %{input | stop_positions: Map.put(input.stop_positions, moved_stop_id, moved)}

      path = stored_path(input)
      {latitude, longitude} = moved

      assert path.straight_pair_count == 2
      assert [Float.round(longitude, 5), Float.round(latitude, 5)] in path.points
    end

    test "refuses a trip whose stops the stop positions lack" do
      input = stored_input()
      missing_stop_id = Enum.at(first_trip_stop_ids(), 2)
      input = %{input | stop_positions: Map.delete(input.stop_positions, missing_stop_id)}

      %{paths: %{@trip_id => outcome}} = TripPath.build_route(input)

      assert outcome == {:error, :stop_positions_missing}
    end
  end

  describe "build_route/1 over a synthetic line" do
    test "draws a straight line where the route has no polyline" do
      stop_positions = %{"a" => @origin, "b" => east_of(@origin, 300)}

      %{paths: %{"trip" => {:ok, path}}} =
        TripPath.build_route(%{
          polylines: [],
          stop_positions: stop_positions,
          trips: [synthetic_trip(["a", "b"])]
        })

      assert path.straight_pair_count == 1
      assert length(TripPath.decode(path).points) == 2
    end

    test "draws a straight line where the polyline's stretch is longer than the bound" do
      # A U whose arms end 100 m apart and run 500 m out: the stretch along
      # it is about 1,100 m, past 2.5 times 100 m plus 150 m.
      top_left = north_of(@origin, 500)
      bottom_right = east_of(@origin, 100)
      top_right = north_of(bottom_right, 500)

      {:ok, path} =
        synthetic_path(%{
          line: [top_left, @origin, bottom_right, top_right],
          stop_positions: %{"a" => top_left, "b" => top_right},
          stop_ids: ["a", "b"]
        })

      assert path.straight_pair_count == 1
    end

    test "follows a polyline whose stretch is within the bound" do
      corner = east_of(@origin, 300)
      far = north_of(corner, 300)

      {:ok, path} =
        synthetic_path(%{
          line: [@origin, corner, far],
          stop_positions: %{"a" => @origin, "b" => far},
          stop_ids: ["a", "b"]
        })

      {latitude, longitude} = corner

      assert path.matched_pair_count == 1
      assert [Float.round(longitude, 5), Float.round(latitude, 5)] in path.points
      assert_in_delta path.length_m, 600, 2
    end

    test "draws a straight line where the polyline runs from the second stop to the first" do
      east = east_of(@origin, 400)

      {:ok, path} =
        synthetic_path(%{
          line: [east, @origin],
          stop_positions: %{"a" => @origin, "b" => east},
          stop_ids: ["a", "b"]
        })

      assert path.straight_pair_count == 1
    end

    test "takes the pass of a line that serves the stops in order on a road it runs both ways" do
      # Out 400 m east and back on the same road, 20 m to the north: the
      # stops lie on the way back, so the stretch is the return leg alone.
      east = east_of(@origin, 400)
      back_east = north_of(east, 20)
      back = north_of(@origin, 20)

      {:ok, path} =
        synthetic_path(%{
          line: [@origin, east, back_east, back],
          stop_positions: %{"a" => north_of(east_of(@origin, 300), 20), "b" => back},
          stop_ids: ["a", "b"]
        })

      assert path.matched_pair_count == 1
      assert_in_delta path.length_m, 300, 2
    end

    test "builds a path of one point for a trip of one stop" do
      {:ok, path} =
        synthetic_path(%{
          line: [@origin, east_of(@origin, 100)],
          stop_positions: %{"a" => @origin},
          stop_ids: ["a"]
        })

      assert path.stop_distances_m == [0]
      assert path.length_m == 0
      assert length(path.points) == 1
    end
  end

  describe "the encoded path" do
    test "puts the last stop where the decoded points, measured by haversine, end" do
      path = stored_path(stored_input())

      length_m =
        path.points
        |> Enum.map(fn [longitude, latitude] -> {latitude, longitude} end)
        |> Enum.chunk_every(2, 1, :discard)
        |> Enum.map(fn [from, to] -> distance_m(from, to) end)
        |> Enum.sum()

      assert List.last(path.stop_distances_m) == round(length_m)
    end

    test "is the one the shared fixture holds, which the browser's check decodes" do
      %{paths: %{@trip_id => {:ok, path}}} = TripPath.build_route(stored_input())
      %{"event" => event} = fixture("encoded_loop")

      assert {path.points, path.stops} == {event["points"], event["stops"]}
    end

    test "holds a stored trip's path in under 2 KB" do
      %{paths: %{@trip_id => {:ok, path}}} = TripPath.build_route(stored_input())

      assert byte_size(path.points) + byte_size(path.stops) < 2_048
    end
  end
end
