defmodule GobusgoWeb.VehicleLiveTripPathsTest do
  # Mounts the vehicle page with Phoenix.LiveViewTest and sends it the
  # browser's trip paths request, with the application's route path view,
  # stop view, schedule view, and trip path cache filled from the stored
  # loop route 1_7994 of 2026-11-09 with the record values their records
  # modules build. All are global state, hence the non-async case. The
  # tests observe the reply to the request and the event the page pushes
  # once the paths are served.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RoutePathBatch
  alias Gobusgo.OneBusAway.RoutePaths
  alias Gobusgo.OneBusAway.RouteScheduleBatch
  alias Gobusgo.OneBusAway.RouteSchedules
  alias Gobusgo.OneBusAway.RouteScheduleView
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.OneBusAway.TripPath
  alias Gobusgo.OneBusAway.TripPathCache
  alias Gobusgo.OneBusAway.TripPathsServed

  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @paths_event "trip-paths:paths"
  @request_event "trip-paths:request"
  @route_path_view Gobusgo.OneBusAway.RoutePathView
  @fixture_directory Path.expand("../../fixtures/one_bus_away/trip_path", __DIR__)
  @route_id "1_7994"
  @trip_id "1_1137791"
  @service_date_ms 1_794_211_200_000
  @fetched_at ~U[2026-11-09 04:20:32Z]
  @push_timeout_ms 2_000

  setup do
    restart_views()
    on_exit(&restart_views/0)
  end

  defp restart_views do
    for child <- [@route_path_view, StopView, RouteScheduleView, TripPathCache] do
      :ok = Supervisor.terminate_child(Gobusgo.Supervisor, child)
      {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, child)
    end
  end

  defp fixture(name) do
    @fixture_directory |> Path.join(name <> ".json") |> File.read!() |> JSON.decode!()
  end

  defp hold_route do
    {:ok, route_path} = RoutePaths.parse(fixture("stops_for_route_loop")["data"], @route_id)

    parsed = %{
      route_id: @route_id,
      route_path: route_path,
      request_id: Gobusgo.RequestId.generate(),
      fetched_at: @fetched_at,
      data_sha256: String.duplicate("0", 64),
      destination: "raw/oba/stops-for-route/test"
    }

    :ok = FetchView.apply_records(@route_path_view, [RoutePathBatch.Records.build(parsed).value])
    :ok = StopView.apply_records(StopView, [RoutePathBatch.StopRecords.build(parsed).value])

    {:ok, schedule} = RouteSchedules.parse(fixture("schedule_for_route_loop")["data"], @route_id)

    record =
      RouteScheduleBatch.Records.build(%{
        route_id: @route_id,
        service_date: ~D[2026-11-09],
        request_id: Gobusgo.RequestId.generate(),
        fetched_at: @fetched_at,
        data_sha256: String.duplicate("0", 64),
        destination: "raw/oba/schedule-for-route/test",
        schedule: schedule
      })

    :ok = RouteScheduleView.apply_records(RouteScheduleView, [record.value])
  end

  defp trip do
    %{"trip_id" => @trip_id, "route_id" => @route_id, "service_date_ms" => @service_date_ms}
  end

  defp mounted do
    {:ok, view, _html} = live(build_conn(), "/vehicles")
    view
  end

  test "accepts a request for trips it can read" do
    view = mounted()

    render_hook(view, @request_event, %{"trips" => [trip()]})

    assert_reply(view, %{accepted: true})
  end

  test "pushes the path of a trip the views hold" do
    hold_route()
    view = mounted()

    render_hook(view, @request_event, %{"trips" => [trip()]})

    assert_push_event(view, @paths_event, %{paths: [path], missing: []}, @push_timeout_ms)
    assert %{trip_id: @trip_id, route_id: @route_id, service_date_ms: @service_date_ms} = path
    assert length(TripPath.decode(path).stop_distances_m) == 8
  end

  test "pushes the reason a trip has no path" do
    view = mounted()

    render_hook(view, @request_event, %{"trips" => [trip()]})

    assert_push_event(
      view,
      @paths_event,
      %{paths: [], missing: [%{trip_id: @trip_id, reason: "route_path_missing"}]},
      @push_timeout_ms
    )
  end

  test "counts the request and its trips once they are served" do
    hold_route()
    TripPathsServed.flush()
    view = mounted()

    render_hook(view, @request_event, %{"trips" => [trip()]})

    assert_push_event(view, @paths_event, %{paths: [_path]}, @push_timeout_ms)
    assert TripPathsServed.flush() == %{request_count: 1, trip_count: 1}
  end

  test "counts a trip with no path as served" do
    TripPathsServed.flush()
    view = mounted()

    render_hook(view, @request_event, %{"trips" => [trip()]})

    assert_push_event(view, @paths_event, %{missing: [_missing]}, @push_timeout_ms)
    assert TripPathsServed.flush() == %{request_count: 1, trip_count: 1}
  end

  test "counts nothing for a request it refuses" do
    TripPathsServed.flush()
    view = mounted()

    render_hook(view, @request_event, %{"trips" => "every trip"})

    assert_reply(view, %{refused: true})
    assert TripPathsServed.flush() == %{request_count: 0, trip_count: 0}
  end

  test "refuses a request it cannot read" do
    view = mounted()

    render_hook(view, @request_event, %{"trips" => "every trip"})

    assert_reply(view, %{refused: true})
  end
end
