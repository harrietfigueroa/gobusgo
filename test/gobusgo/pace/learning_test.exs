defmodule Gobusgo.Pace.LearningTest do
  # Checks the pace learning rules on values: a straight path running east
  # from a point in Seattle, reports placed by meters along it, and the
  # cells that pairs of reports add to. No process runs.
  use ExUnit.Case, async: true

  alias Gobusgo.Math.Geodesy
  alias Gobusgo.Pace.Learning

  @origin_lon -122.34
  @origin_lat 47.6
  @trip_key {"1_trip", 1_700_000_000_000}
  @start_ms 1_700_000_000_000
  @tolerance 1.0e-6

  defp east_path do
    Learning.prepare_path(%{
      points: [[@origin_lon, @origin_lat], [@origin_lon + 0.01, @origin_lat]]
    })
  end

  defp meters_per_degree_lon,
    do: Geodesy.meters_per_degree() * :math.cos(Geodesy.radians(@origin_lat))

  defp east_position(meters, north_m \\ 0) do
    %{
      lon: @origin_lon + meters / meters_per_degree_lon(),
      lat: @origin_lat + north_m / Geodesy.meters_per_degree()
    }
  end

  defp report(meters, seconds, overrides \\ %{}) do
    Map.merge(
      %{
        vehicle_key: {"1", "v1"},
        trip_key: @trip_key,
        route_id: "1_route",
        position: east_position(meters),
        at_ms: @start_ms + seconds * 1000
      },
      overrides
    )
  end

  defp advance(report, previous, path \\ east_path()) do
    Learning.advance(%{previous: previous, report: report, path: path})
  end

  defp placed_at(meters, seconds) do
    %{trip_key: @trip_key, meters: meters, at_ms: @start_ms + seconds * 1000}
  end

  describe "spread/1" do
    for {name, input, expected} <- [
          {"a pair inside one step", %{seconds: 8, from_m: 12, to_m: 17}, [{1, 8, 5}]},
          {"a stand", %{seconds: 30, from_m: 12, to_m: 12}, [{1, 30, 0}]},
          {"a pair ending on a step's start", %{seconds: 10, from_m: 10, to_m: 20},
           [{1, 10, 10}]},
          {"a pair across steps", %{seconds: 10, from_m: 5, to_m: 25},
           [{0, 2.5, 5}, {1, 5.0, 10}, {2, 2.5, 5}]}
        ] do
      test "spreads #{name}" do
        assert Learning.spread(unquote(Macro.escape(input))) == unquote(Macro.escape(expected))
      end
    end
  end

  describe "project/3" do
    test "finds the distance along the path" do
      assert {:on_path, along} = Learning.project(east_path(), east_position(100), 0)
      assert_in_delta along, 100, 0.5
    end

    test "drops a position more than 60 m off the path" do
      assert Learning.project(east_path(), east_position(100, 61), 0) == :off_path
    end

    test "keeps a position 59 m off the path" do
      assert {:on_path, _along} = Learning.project(east_path(), east_position(100, 59), 0)
    end

    test "drops a position before the earliest allowed distance" do
      assert Learning.project(east_path(), east_position(100), 400) == :off_path
    end
  end

  describe "cell_key/2" do
    for {name, points, direction} <- [
          {"east", [[@origin_lon, @origin_lat], [@origin_lon + 0.01, @origin_lat]], 2},
          {"north", [[@origin_lon, @origin_lat], [@origin_lon, @origin_lat + 0.01]], 0},
          {"south", [[@origin_lon, @origin_lat + 0.01], [@origin_lon, @origin_lat]], 4},
          {"west", [[@origin_lon + 0.01, @origin_lat], [@origin_lon, @origin_lat]], 6},
          {"just west of north",
           [[@origin_lon, @origin_lat], [@origin_lon - 0.0001, @origin_lat + 0.01]], 0}
        ] do
      test "buckets travel #{name} as direction #{direction}" do
        path = Learning.prepare_path(%{points: unquote(points)})
        assert {_lon_cell, _lat_cell, unquote(direction)} = Learning.cell_key(path, 0)
      end
    end

    test "floors the position into the grid" do
      assert Learning.cell_key(east_path(), 0) ==
               {floor(@origin_lon / 0.00045), floor(@origin_lat / 0.0003), 2}
    end

    test "clamps a distance past the path's end to the end" do
      path = east_path()

      assert Learning.cell_key(path, path.length_m + 500) ==
               Learning.cell_key(path, path.length_m)
    end
  end

  describe "advance/1" do
    test "places the first report and adds no cell" do
      assert %{placed: %{meters: meters, at_ms: at_ms}, cells: []} = advance(report(100, 0), nil)
      assert_in_delta meters, 100, 0.5
      assert at_ms == @start_ms
    end

    test "spreads a usable pair's seconds and meters over the cells it covered" do
      %{cells: cells} = advance(report(105, 10), placed_at(5.0, 0))
      assert cells != []
      assert_in_delta Enum.sum(for({_key, seconds, _meters} <- cells, do: seconds)), 10, 0.01
      assert_in_delta Enum.sum(for({_key, _seconds, meters} <- cells, do: meters)), 100, 0.5
    end

    test "gives a stand's seconds to the cell it stands in" do
      %{placed: previous} = advance(report(100, 0), nil)
      assert %{cells: [{_key, seconds, meters}]} = advance(report(100, 30), previous)
      assert_in_delta seconds, 30, @tolerance
      assert_in_delta meters, 0, 0.01
    end

    for {name, previous_meters, meters, seconds} <- [
          {"a gap of 91 s", 0.0, 100, 91},
          {"a speed past 30 m/s", 0.0, 310, 10},
          {"no time between the reports", 0.0, 100, 0}
        ] do
      test "adds no cell for #{name}" do
        assert %{placed: %{}, cells: []} =
                 advance(
                   report(unquote(meters), unquote(seconds)),
                   placed_at(unquote(previous_meters), 0)
                 )
      end
    end

    test "uses a gap of exactly 90 s and a speed of exactly 30 m/s" do
      assert %{cells: [_ | _]} = advance(report(2700, 90), placed_at(0.0, 0), long_east_path())
    end

    test "places a vehicle that went backward nowhere" do
      assert %{placed: nil, cells: []} = advance(report(90, 10), placed_at(100.0, 0))
    end

    test "places a vehicle more than 60 m off the path nowhere" do
      off = report(100, 10, %{position: east_position(100, 100)})
      assert %{placed: nil, cells: []} = advance(off, placed_at(0.0, 0))
    end

    test "starts again on another trip" do
      other = report(100, 10, %{trip_key: {"1_other", @start_ms}})
      assert %{placed: %{trip_key: {"1_other", _}}, cells: []} = advance(other, placed_at(0.0, 0))
    end

    test "places a vehicle with no path nowhere" do
      assert %{placed: nil, cells: []} = advance(report(100, 10), placed_at(0.0, 0), nil)
    end
  end

  describe "reports/1" do
    @vehicle %{
      id: "v1",
      active_trip_id: "1_trip",
      route_id: "1_route",
      service_date_ms: 1_700_000_000_000,
      last_known_location: %{lat: 47.6, lon: -122.3},
      last_location_update_time_ms: 1_700_000_050_000
    }

    test "reports a vehicle with a trip, a route, a service date, and a reported location" do
      assert [report] = Learning.reports(%{agency_id: "1", vehicles: [@vehicle]})
      assert report.vehicle_key == {"1", "v1"}
      assert report.trip_key == {"1_trip", 1_700_000_000_000}
      assert report.position == %{lon: -122.3, lat: 47.6}
      assert report.at_ms == 1_700_000_050_000
    end

    for {name, change} <- [
          {"no trip", %{active_trip_id: nil}},
          {"no route", %{route_id: nil}},
          {"no service date", %{service_date_ms: nil}},
          {"no location", %{last_known_location: nil}},
          {"never reported a location", %{last_location_update_time_ms: 0}},
          {"no location time", %{last_location_update_time_ms: nil}}
        ] do
      test "leaves out a vehicle with #{name}" do
        vehicle = Map.merge(@vehicle, unquote(Macro.escape(change)))
        assert Learning.reports(%{agency_id: "1", vehicles: [vehicle]}) == []
      end
    end
  end

  defp long_east_path do
    Learning.prepare_path(%{
      points: [[@origin_lon, @origin_lat], [@origin_lon + 0.1, @origin_lat]]
    })
  end
end
