defmodule GobusgoWeb.VehicleLiveTripTest do
  # Mounts the vehicle page with Phoenix.LiveViewTest over a basemap manifest
  # the test writes to its temporary directory and the application's vehicle
  # view, route view, and stop view, filled with the record values their
  # records modules build. All are global state, hence the non-async case.
  # The browser plans the journey, so these tests observe what the page
  # answers the trip planner's events with: the names of a journey's stops
  # and routes, and the markers, the kept routes, and the summary of the
  # trip's temporary filter, which is neither stored nor put in the address.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RoutePathBatch.StopRecords
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.OneBusAway.VehicleBatch.Records
  alias Gobusgo.OneBusAway.VehicleView
  alias GobusgoWeb.VehicleLive.Trip

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @markers_event "vehicle-markers:agency"
  @store_event "vehicle-filter:store"
  @ended_event "trip:filter-ended"
  @planner "#trip-planner"
  @tiles "#route-stop-tiles"
  @route_view Gobusgo.OneBusAway.RouteView
  @fetched_at ~U[2026-11-08 17:00:00Z]
  @bounds %{"south" => 47.0, "west" => -123.0, "north" => 48.0, "east" => -122.0}
  @manifest %{
    "snapshot" => "20261004",
    "archives" => [%{"name" => "basemap-20261004-01.pmtiles", "bounds" => @bounds}],
    "agencies" => [
      %{"agencyId" => "1", "archive" => "basemap-20261004-01.pmtiles", "bounds" => @bounds}
    ]
  }

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:gobusgo, :basemap)
    Application.put_env(:gobusgo, :basemap, dir: tmp_dir)
    File.write!(Path.join(tmp_dir, "manifest.json"), JSON.encode!(@manifest))
    restart_views()

    on_exit(fn ->
      Application.put_env(:gobusgo, :basemap, configured)
      restart_views()
    end)
  end

  defp restart_views do
    for view <- [VehicleView, StopView, @route_view] do
      :ok = Supervisor.terminate_child(Gobusgo.Supervisor, view)
      {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, view)
    end
  end

  defp request_id(sequence) do
    "0199c4a2-7e1b-7a3f-9d20-" <> String.pad_leading(Integer.to_string(sequence), 12, "0")
  end

  # Publishes agency "1"'s routes E, 36, and 7, each `{id, short name, color}`.
  defp apply_routes do
    routes =
      for {id, short_name, color} <- [
            {"1_102576", "E", "1D4ED8"},
            {"1_100210", "36", "EA580C"},
            {"1_100275", "7", nil}
          ] do
        %{
          id: id,
          agency_id: "1",
          short_name: short_name,
          long_name: "Long " <> short_name,
          description: nil,
          type: 3,
          color: color,
          text_color: nil,
          url: nil
        }
      end

    record =
      RouteBatch.Records.build(%{
        agency_id: "1",
        destination: "raw/oba/routes-for-agency/dt=2026-11-08/agency=1/file.json.gz",
        fetched_at: @fetched_at,
        data_sha256: String.duplicate("ab", 32),
        request_id: request_id(0),
        routes: routes
      })

    :ok = FetchView.apply_records(@route_view, [record.value])
  end

  # Publishes the stops of one route: 3rd Ave & Pike St with a code, and
  # Rainier Ave S & S Othello St with none.
  defp apply_stops do
    stops =
      for {id, name, code} <- [
            {"1_431", "3rd Ave & Pike St", "431"},
            {"1_11920", "Rainier Ave S & S Othello St", nil}
          ] do
        %{
          id: id,
          name: name,
          lat: 47.6,
          lon: -122.3,
          code: code,
          direction: "N",
          location_type: 0,
          parent: nil,
          wheelchair_boarding: "UNKNOWN",
          route_ids: ["1_100210"]
        }
      end

    record =
      StopRecords.build(%{
        route_id: "1_100210",
        destination: "raw/oba/stops-for-route/dt=2026-11-08/route=1_100210/file.json.gz",
        fetched_at: @fetched_at,
        data_sha256: String.duplicate("ab", 32),
        request_id: request_id(0),
        route_path: %{
          route_id: "1_100210",
          stop_ids: ["1_431", "1_11920"],
          polylines: [],
          stop_groupings: [],
          stops: stops,
          parent_stops: []
        }
      })

    :ok = StopView.apply_records(StopView, [record.value])
  end

  defp vehicle({id, route_id}) do
    %{
      id: id,
      active_trip_id: nil,
      route_id: route_id,
      route_short_name: nil,
      route_long_name: nil,
      trip_headsign: nil,
      position: %{lat: 47.66, lon: -122.34},
      orientation: nil,
      last_known_location: nil,
      last_known_orientation: nil,
      last_update_time_ms: nil,
      last_location_update_time_ms: DateTime.to_unix(@fetched_at, :millisecond),
      predicted: true,
      schedule_deviation_seconds: nil,
      next_stop_id: nil,
      next_stop_time_offset_seconds: nil,
      service_date_ms: nil
    }
  end

  # Agency "1" with one vehicle on each of E, 36, and 7.
  defp apply_vehicles do
    %{vehicles: records, manifest: manifest} =
      Records.build(%{
        agency_id: "1",
        destination: "raw/oba/vehicles-for-agency/dt=2026-11-08/agency=1/file.json",
        fetched_at: @fetched_at,
        data_sha256: String.duplicate("ab", 32),
        request_id: request_id(1),
        vehicles:
          Enum.map(
            [{"1_e", "1_102576"}, {"1_36", "1_100210"}, {"1_7", "1_100275"}],
            &vehicle/1
          )
      })

    :ok = VehicleView.apply_records(VehicleView, Enum.map(records ++ [manifest], & &1.value))
  end

  # The page at `path` after its map asked for the markers, with the
  # markers of that first ask read.
  defp open_ready(path) do
    apply_routes()
    apply_vehicles()
    {:ok, view, _html} = live(build_conn(), path)
    view |> element("#vehicle-markers") |> render_hook("vehicle-markers:ready")
    assert_push_event(view, @markers_event, %{agency_id: "1"})
    view
  end

  defp hook(view, event, params), do: view |> element(@planner) |> render_hook(event, params)

  defp kept_route_ids(view) do
    view
    |> element(@tiles)
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.attribute("data-route-ids")
    |> case do
      [value] -> JSON.decode!(value)
      [] -> :every
    end
  end

  defp summary(view) do
    view
    |> element("#panel-sheet-summary")
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.text()
  end

  defp marker_ids(markers), do: Enum.map(markers, & &1.id)

  describe "the trip planner's element" do
    test "carries the manifest's address and the bounds of a request" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      html = view |> element(@planner) |> render()

      assert html =~ ~s(phx-hook="TripPlanner")
      assert html =~ ~s(data-manifest-url="/api/routing/manifest")
      assert html =~ ~s(data-name-count-max="#{Trip.name_count_max()}")
      assert html =~ ~s(data-route-count-max="#{Trip.route_count_max()}")
    end
  end

  describe "the names of a journey" do
    test "answers each held stop's name and code and each held route's name and color" do
      apply_routes()
      apply_stops()
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      hook(view, "trip:names", %{
        "stop_ids" => ["1_431", "1_11920"],
        "route_ids" => ["1_102576", "1_100275"]
      })

      assert_reply(view, %{
        stops: %{
          "1_431" => %{name: "3rd Ave & Pike St", code: "431"},
          "1_11920" => %{name: "Rainier Ave S & S Othello St", code: nil}
        },
        routes: %{
          "1_102576" => %{name: "E", color: "#1D4ED8"},
          "1_100275" => %{name: "7", color: "#6b7280"}
        }
      })
    end

    test "leaves out a stop and a route the views do not hold" do
      apply_routes()
      apply_stops()
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      hook(view, "trip:names", %{"stop_ids" => ["1_999"], "route_ids" => ["40_999"]})

      assert_reply(view, %{stops: stops, routes: routes})
      assert stops == %{}
      assert routes == %{}
    end

    test "refuses a request of more identifiers than its bound" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      stop_ids = for index <- 0..Trip.name_count_max(), do: "1_#{index}"

      hook(view, "trip:names", %{"stop_ids" => stop_ids, "route_ids" => []})

      assert_reply(view, %{refused: true})
    end

    test "refuses a request whose identifiers are not text" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      hook(view, "trip:names", %{"stop_ids" => [1], "route_ids" => []})

      assert_reply(view, %{refused: true})
    end
  end

  describe "a trip's filter" do
    test "sends the markers of the journey's routes alone" do
      view = open_ready("/vehicles")

      hook(view, "trip:filter", %{"route_ids" => ["1_102576", "1_100210"]})

      assert_push_event(view, @markers_event, %{agency_id: "1", markers: markers})
      assert marker_ids(markers) == ["1/1_36", "1/1_e"]
    end

    test "keeps the journey's routes for the lines and the stops" do
      view = open_ready("/vehicles")

      hook(view, "trip:filter", %{"route_ids" => ["1_102576", "1_100210"]})

      assert kept_route_ids(view) == ["1_100210", "1_102576"]
    end

    test "names the trip's routes in the summary" do
      view = open_ready("/vehicles")

      hook(view, "trip:filter", %{"route_ids" => ["1_102576", "1_100210"]})

      assert summary(view) =~ "Showing the trip's routes: E, 36"
    end

    test "is not stored" do
      view = open_ready("/vehicles")

      hook(view, "trip:filter", %{"route_ids" => ["1_102576"]})

      refute_push_event(view, @store_event, %{})
    end

    test "is not put in the address" do
      view = open_ready("/vehicles?route=1_100275")

      hook(view, "trip:filter", %{"route_ids" => ["1_102576"]})

      refute_received {_ref, {:patch, _topic, _to}}
      assert view |> element("#vehicle-filter") |> render() =~ ~s(data-supplied="true")
    end

    test "switches to another journey's routes" do
      view = open_ready("/vehicles")
      hook(view, "trip:filter", %{"route_ids" => ["1_102576"]})
      assert_push_event(view, @markers_event, %{agency_id: "1"})

      hook(view, "trip:filter", %{"route_ids" => ["1_100275"]})

      assert_push_event(view, @markers_event, %{agency_id: "1", markers: [%{id: "1/1_7"}]})
    end

    test "refuses more routes than its bound and changes nothing" do
      view = open_ready("/vehicles")
      route_ids = for index <- 0..Trip.route_count_max(), do: "1_#{index}"

      hook(view, "trip:filter", %{"route_ids" => route_ids})

      refute_push_event(view, @markers_event, %{})
      assert kept_route_ids(view) == :every
    end
  end

  describe "clearing the trip" do
    test "brings back the rider's own filter" do
      view = open_ready("/vehicles?route=1_100275")
      hook(view, "trip:filter", %{"route_ids" => ["1_102576"]})

      hook(view, "trip:clear", %{})

      assert kept_route_ids(view) == ["1_100275"]
      assert_push_event(view, @markers_event, %{agency_id: "1", markers: [%{id: "1/1_7"}]})
    end

    test "names the rider's filter in the summary again" do
      view = open_ready("/vehicles")
      hook(view, "trip:filter", %{"route_ids" => ["1_102576"]})

      hook(view, "trip:clear", %{})

      assert summary(view) =~ "every vehicle"
    end
  end

  describe "an edit to the filter bar while a trip is open" do
    test "ends the trip's filter and stores the edit" do
      view = open_ready("/vehicles")
      hook(view, "trip:filter", %{"route_ids" => ["1_102576", "1_100210"]})

      view
      |> element("#vehicle-filter-tokens button[phx-value-id='1_100210']")
      |> render_click()

      assert_push_event(view, @ended_event, %{})
      assert_push_event(view, @store_event, %{filter: %{"route" => ["1_102576"]}})
      assert_patch(view, "/vehicles?route=1_102576")
    end

    test "leaves the trip's routes out of the summary" do
      view = open_ready("/vehicles")
      hook(view, "trip:filter", %{"route_ids" => ["1_102576", "1_100210"]})

      view
      |> element("#vehicle-filter-tokens button[phx-value-id='1_100210']")
      |> render_click()

      refute summary(view) =~ "the trip's routes"
    end
  end
end
