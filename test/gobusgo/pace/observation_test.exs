defmodule Gobusgo.Pace.ObservationTest do
  # Drives the learning step of one fetch with reports written out by hand
  # and a path source that serves one straight path, and reads the state it
  # returns.
  use ExUnit.Case, async: true

  alias Gobusgo.Math.Geodesy
  alias Gobusgo.Pace.Learning
  alias Gobusgo.Pace.Observation
  alias Gobusgo.Pace.Table

  @origin_lon -122.34
  @origin_lat 47.6
  @service_date_ms 1_700_000_000_000
  @start_ms 1_700_000_000_000

  defp east_path do
    Learning.prepare_path(%{
      points: [[@origin_lon, @origin_lat], [@origin_lon + 0.01, @origin_lat]]
    })
  end

  defp serve_east_path(%{trip_id: "east"}, _views), do: {:ok, east_path()}
  defp serve_east_path(%{trip_id: "raises"}, _views), do: raise("the view is gone")
  defp serve_east_path(%{trip_id: _other}, _views), do: :unavailable

  defp options(overrides \\ %{}) do
    Map.merge(
      %{
        path_source: &serve_east_path/2,
        views: %{},
        vehicle_count_max: 100,
        path_count_max: 100,
        path_build_count_max: 100
      },
      overrides
    )
  end

  defp state, do: Observation.new(Table.new(%{date: ~D[2026-11-11], cell_count_max: 1_000}))

  defp report(meters, seconds, overrides \\ %{}) do
    meters_per_degree_lon = Geodesy.meters_per_degree() * :math.cos(Geodesy.radians(@origin_lat))

    Map.merge(
      %{
        vehicle_key: {"1", "v1"},
        trip_key: {"east", @service_date_ms},
        route_id: "1_route",
        position: %{lon: @origin_lon + meters / meters_per_degree_lon, lat: @origin_lat},
        at_ms: @start_ms + seconds * 1000
      },
      overrides
    )
  end

  defp learn(state, reports, options \\ options()) do
    Observation.learn(%{state: state, reports: reports, options: options})
  end

  defp seconds_total(%{table: table}) do
    Enum.sum(for {_key, {seconds, _meters}} <- table.cells, do: seconds)
  end

  test "learns the cells between a vehicle's two reports" do
    learned = state() |> learn([report(5, 0)]) |> learn([report(105, 10)])

    assert_in_delta seconds_total(learned), 10, 0.01
    assert_in_delta Table.meters_total(learned.table), 100, 0.5
  end

  test "learns nothing from the first report of a vehicle" do
    learned = learn(state(), [report(5, 0)])

    assert learned.table.cells == %{}
    assert map_size(learned.vehicles) == 1
  end

  test "learns nothing from a report that repeats the last" do
    once = state() |> learn([report(5, 0)]) |> learn([report(105, 10)])
    twice = learn(once, [report(105, 10)])

    assert twice.table == once.table
  end

  test "learns the same table from one fetch of two reports as from two fetches of one" do
    together = learn(state(), [report(5, 0), report(105, 10)])
    apart = state() |> learn([report(5, 0)]) |> learn([report(105, 10)])

    assert together.table == apart.table
  end

  test "leaves the state as it was for a fetch with no report" do
    held = learn(state(), [report(5, 0)])
    assert learn(held, []) == held
  end

  test "places no vehicle where the trip has no path" do
    trip_key = {"missing", @service_date_ms}
    learned = learn(state(), [report(5, 0, %{trip_key: trip_key})])

    assert learned.vehicles == %{}
    assert learned.paths == %{}
  end

  test "holds a path it has read and reads it once" do
    counter = :counters.new(1, [])

    path_source = fn trip, views ->
      :counters.add(counter, 1, 1)
      serve_east_path(trip, views)
    end

    options = options(%{path_source: path_source})
    state() |> learn([report(5, 0)], options) |> learn([report(105, 10)], options)

    assert :counters.get(counter, 1) == 1
  end

  test "reads no more paths in a step than its bound" do
    options = options(%{path_build_count_max: 1})
    other = %{vehicle_key: {"1", "v2"}, trip_key: {"east", @service_date_ms + 1}}
    learned = learn(state(), [report(5, 0), report(5, 0, other)], options)

    assert Map.keys(learned.vehicles) == [{"1", "v1"}]
  end

  test "drops every held path at the path bound" do
    options = options(%{path_count_max: 1})
    other = %{vehicle_key: {"1", "v2"}, trip_key: {"east", @service_date_ms + 1}}
    learned = learn(state(), [report(5, 0), report(5, 0, other)], options)

    assert Map.keys(learned.paths) == [{"east", @service_date_ms + 1}]
  end

  test "forgets every vehicle at the vehicle bound" do
    options = options(%{vehicle_count_max: 1})
    other = %{vehicle_key: {"1", "v2"}}
    learned = learn(state(), [report(5, 0), report(5, 0, other)], options)

    assert learned.vehicles == %{}
  end

  test "forgets a vehicle a later report finds too old to pair" do
    learned =
      state() |> learn([report(5, 0)]) |> learn([report(5, 500, %{vehicle_key: {"1", "v2"}})])

    assert Map.keys(learned.vehicles) == [{"1", "v2"}]
  end

  test "returns the first error a path read raised and learns on" do
    raising = %{trip_key: {"raises", @service_date_ms}}
    learned = learn(state(), [report(5, 0, raising), report(5, 0, %{vehicle_key: {"1", "v2"}})])

    assert %{message: "the view is gone", stack: stack} = learned.path_error
    assert is_binary(stack)
    assert Map.keys(learned.vehicles) == [{"1", "v2"}]
  end
end
