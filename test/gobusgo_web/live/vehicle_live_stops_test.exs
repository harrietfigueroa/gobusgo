defmodule GobusgoWeb.VehicleLiveStopsTest do
  # Mounts the vehicle page with Phoenix.LiveViewTest over a basemap manifest
  # the test writes to its temporary directory and the application's two
  # route views and stop view, filled with the record values their records
  # modules build. All are global state, hence the non-async case. The
  # browser draws the stops, so these tests observe what the page hands it:
  # the events that carry the stops' markers, and the element the stop hook
  # mounts on.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.OneBusAway.AgencyBatch
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RoutePathBatch
  alias Gobusgo.OneBusAway.StopView
  alias GobusgoWeb.StopMarkers

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @event "stop-markers:stops"
  @push_wait_ms 50
  @route_view Gobusgo.OneBusAway.RouteView
  @route_path_view Gobusgo.OneBusAway.RoutePathView
  @fetched_at ~U[2026-10-05 01:00:00Z]
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
    for view <- [AgencyView, @route_view, @route_path_view, StopView] do
      :ok = Supervisor.terminate_child(Gobusgo.Supervisor, view)
      {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, view)
    end
  end

  defp request_id(sequence) do
    "0199c4a2-7e1b-7a3f-9d20-" <> String.pad_leading(Integer.to_string(sequence), 12, "0")
  end

  defp parsed(%{route_id: route_id, sequence: sequence}, route_path) do
    %{
      route_id: route_id,
      destination: "raw/oba/stops-for-route/dt=2026-10-05/route=#{route_id}/file.json.gz",
      fetched_at: DateTime.add(@fetched_at, sequence, :second),
      data_sha256: String.duplicate("ab", 32),
      request_id: request_id(sequence),
      route_path:
        Map.merge(
          %{
            route_id: route_id,
            stop_ids: [],
            polylines: [],
            stop_groupings: [],
            stops: [],
            parent_stops: []
          },
          route_path
        )
    }
  end

  defp stop(id, overrides) do
    Map.merge(
      %{
        id: id,
        name: "Stop " <> id,
        lat: 47.6,
        lon: -122.3,
        code: nil,
        direction: nil,
        location_type: 0,
        parent: nil,
        wheelchair_boarding: "UNKNOWN",
        route_ids: []
      },
      overrides
    )
  end

  # Publishes a fetch of agencies, each `{id, name}`; `sequence` orders the
  # fetches of a test.
  defp apply_agencies(agencies, sequence) do
    %{agencies: records, manifest: manifest} =
      AgencyBatch.Records.build(%{
        destination: "raw/oba/agencies-with-coverage/dt=2026-10-05/file.json.gz",
        fetched_at: DateTime.add(@fetched_at, sequence, :second),
        data_sha256: String.duplicate("ab", 32),
        request_id: request_id(sequence),
        agencies:
          for {id, name} <- agencies do
            %{
              id: id,
              name: name,
              url: "https://agency-#{id}.example.test",
              timezone: "America/Los_Angeles",
              coverage: %{lat: 47.5, lon: -122.25, lat_span: 0.5, lon_span: 0.75}
            }
          end
      })

    :ok = AgencyView.apply_records(AgencyView, Enum.map(records ++ [manifest], & &1.value))
  end

  # Publishes a fetch of the routes of `agency_id`, each `{id, short name}`;
  # `sequence` orders the fetches of a test.
  defp apply_routes(routes, %{agency_id: agency_id, sequence: sequence}) do
    record =
      RouteBatch.Records.build(%{
        agency_id: agency_id,
        destination: "raw/oba/routes-for-agency/dt=2026-10-05/agency=#{agency_id}/file.json.gz",
        fetched_at: DateTime.add(@fetched_at, sequence, :second),
        data_sha256: String.duplicate("ab", 32),
        request_id: request_id(sequence),
        routes:
          for {id, short_name} <- routes do
            %{
              id: id,
              agency_id: agency_id,
              short_name: short_name,
              long_name: nil,
              description: nil,
              type: 3,
              color: nil,
              text_color: nil,
              url: nil
            }
          end
      })

    :ok = FetchView.apply_records(@route_view, [record.value])
  end

  # Publishes a fetch of the path of the route, which gives the route a line.
  defp apply_path(fetch) do
    record = RoutePathBatch.Records.build(parsed(fetch, %{}))
    :ok = FetchView.apply_records(@route_path_view, [record.value])
  end

  # Publishes a fetch of the stops of the route: `stops` the route lists and
  # `parent_stops` those name.
  defp apply_stops(stops, fetch, parent_stops \\ []) do
    route_path = %{
      stop_ids: Enum.map(stops, & &1.id),
      stops: stops,
      parent_stops: parent_stops
    }

    record = RoutePathBatch.StopRecords.build(parsed(fetch, route_path))
    :ok = StopView.apply_records(StopView, [record.value])
  end

  # One agency with one route that has a line and serves the stops `a` and
  # `b`.
  defp apply_one_route do
    apply_routes([{"40_1", "1 Line"}], %{agency_id: "40", sequence: 1})
    apply_path(%{route_id: "40_1", sequence: 2})

    apply_stops(
      [stop("b", %{route_ids: ["40_1"]}), stop("a", %{route_ids: ["40_1"], code: "17"})],
      %{route_id: "40_1", sequence: 2}
    )
  end

  defp open_page(path \\ "/vehicles") do
    {:ok, view, _html} = live(build_conn(), path)
    view
  end

  defp ready(view), do: view |> element("#stop-markers") |> render_hook("stop-markers:ready")

  defp open_ready(path \\ "/vehicles") do
    view = open_page(path)
    ready(view)
    assert_push_event(view, @event, %{reset: true})
    view
  end

  describe "the page" do
    test "holds the element the stop hook mounts on, shown as nothing" do
      html = open_page() |> element("#stop-markers") |> render()

      assert html =~ ~s(phx-hook="StopMarkers")
      assert html =~ "hidden"
    end

    test "holds the stops' element before the vehicles', so the vehicles are drawn over the stops" do
      html = render(open_page())
      [before_vehicles, _after] = String.split(html, ~s(id="vehicle-markers"), parts: 2)

      assert before_vehicles =~ ~s(id="stop-markers")
    end

    test "holds no stop element when there is no basemap", %{tmp_dir: tmp_dir} do
      File.rm!(Path.join(tmp_dir, "manifest.json"))

      refute open_page() |> has_element?("#stop-markers")
    end
  end

  describe "a switch of the agency view" do
    test "that renames an agency sends every stop again after a reset" do
      apply_agencies([{"40", "Sound Transit"}], 0)
      apply_one_route()
      view = open_page()
      ready(view)
      assert_push_event(view, @event, %{reset: true})

      apply_agencies([{"40", "Sound Transit Express"}], 3)

      assert_push_event(view, @event, %{
        stops: [%{id: "a", agencies: ["Sound Transit Express"]} | _rest],
        reset: true
      })
    end

    test "that leaves every agency's name as it is sends no stop" do
      apply_agencies([{"40", "Sound Transit"}], 0)
      apply_one_route()
      view = open_page()
      ready(view)
      assert_push_event(view, @event, %{reset: true})

      apply_agencies([{"40", "Sound Transit"}], 3)

      refute_push_event(view, @event, %{}, @push_wait_ms)
    end
  end

  describe "the stops' ready event" do
    test "is answered with every stop a drawn route serves, in identifier order, after a reset" do
      apply_one_route()
      view = open_page()

      ready(view)

      assert_push_event(view, @event, %{stops: stops, removed: [], reset: true})

      assert stops == [
               %{
                 id: "a",
                 lat: 47.6,
                 lon: -122.3,
                 name: "Stop a",
                 code: "17",
                 direction: nil,
                 routes: ["1 Line"],
                 agencies: []
               },
               %{
                 id: "b",
                 lat: 47.6,
                 lon: -122.3,
                 name: "Stop b",
                 code: nil,
                 direction: nil,
                 routes: ["1 Line"],
                 agencies: []
               }
             ]
    end

    test "names the agencies of a stop's routes that the agency view holds" do
      apply_agencies([{"40", "Sound Transit"}], 0)
      apply_one_route()
      view = open_page()

      ready(view)

      assert_push_event(view, @event, %{stops: [%{id: "a", agencies: ["Sound Transit"]} | _rest]})
    end

    test "is answered with a reset and no stop when the view holds none" do
      view = open_page()

      ready(view)

      assert_push_event(view, @event, %{stops: [], removed: [], reset: true})
    end

    test "leaves out a parent stop, which no route serves" do
      apply_routes([{"40_1", "1 Line"}], %{agency_id: "40", sequence: 1})
      apply_path(%{route_id: "40_1", sequence: 2})

      apply_stops(
        [stop("a", %{route_ids: ["40_1"], parent: "station"})],
        %{route_id: "40_1", sequence: 2},
        [stop("station", %{})]
      )

      view = open_page()

      ready(view)

      assert_push_event(view, @event, %{stops: [%{id: "a"}]})
    end

    test "leaves out a stop whose routes have no line" do
      apply_routes([{"40_1", "1 Line"}, {"40_2", "2 Line"}], %{agency_id: "40", sequence: 1})
      apply_path(%{route_id: "40_1", sequence: 2})
      apply_stops([stop("a", %{route_ids: ["40_1"]})], %{route_id: "40_1", sequence: 2})
      apply_stops([stop("c", %{route_ids: ["40_2"]})], %{route_id: "40_2", sequence: 3})
      view = open_page()

      ready(view)

      assert_push_event(view, @event, %{stops: [%{id: "a"}]})
    end

    test "is answered in events of at most the bound of stops, the reset in the first" do
      count = StopMarkers.event_stop_count_max() + 1
      apply_routes([{"40_1", "1 Line"}], %{agency_id: "40", sequence: 1})
      apply_path(%{route_id: "40_1", sequence: 2})

      stops =
        for index <- 1..count do
          stop(String.pad_leading(Integer.to_string(index), 4, "0"), %{route_ids: ["40_1"]})
        end

      apply_stops(stops, %{route_id: "40_1", sequence: 2})
      view = open_page()

      ready(view)

      assert_push_event(view, @event, %{stops: [%{id: "0001"} | _rest] = first, reset: true})
      assert length(first) == StopMarkers.event_stop_count_max()
      last_id = String.pad_leading(Integer.to_string(count), 4, "0")
      assert_push_event(view, @event, %{stops: [%{id: ^last_id}], removed: [], reset: false})
    end
  end

  describe "a filter" do
    setup do
      apply_routes([{"40_1", "1 Line"}], %{agency_id: "40", sequence: 1})
      apply_routes([{"1_44", "44"}], %{agency_id: "1", sequence: 2})
      apply_path(%{route_id: "40_1", sequence: 3})
      apply_path(%{route_id: "1_44", sequence: 4})
      apply_stops([stop("a", %{route_ids: ["40_1"]})], %{route_id: "40_1", sequence: 3})
      apply_stops([stop("b", %{route_ids: ["1_44"]})], %{route_id: "1_44", sequence: 4})
    end

    test "by agency sends only the stops of that agency's routes" do
      view = open_page("/vehicles?agency=40")

      ready(view)

      assert_push_event(view, @event, %{stops: [%{id: "a"}], reset: true})
    end

    test "by route sends only the stops of that route" do
      view = open_page("/vehicles?route=1_44")

      ready(view)

      assert_push_event(view, @event, %{stops: [%{id: "b"}], reset: true})
    end

    test "that is refused sends no stop" do
      view = open_page("/vehicles?agency[x]=1")

      ready(view)

      assert_push_event(view, @event, %{stops: [], reset: true})
    end

    test "that changes sends every stop it keeps after a reset" do
      view = open_ready()

      render_patch(view, "/vehicles?agency=1")

      assert_push_event(view, @event, %{stops: [%{id: "b"}], removed: [], reset: true})
    end

    test "that changes before the browser asks sends nothing" do
      view = open_page()

      render_patch(view, "/vehicles?agency=1")

      refute_push_event(view, @event, %{}, @push_wait_ms)
    end
  end

  describe "a change of the stop view" do
    test "sends nothing before the browser asks" do
      view = open_page()

      apply_one_route()

      refute_push_event(view, @event, %{}, @push_wait_ms)
    end

    test "sends a stop whose values changed, without a reset" do
      apply_one_route()
      view = open_ready()

      apply_stops(
        [stop("a", %{route_ids: ["40_1"], name: "Renamed"}), stop("b", %{route_ids: ["40_1"]})],
        %{route_id: "40_1", sequence: 5}
      )

      assert_push_event(view, @event, %{
        stops: [%{id: "a", name: "Renamed"}, %{id: "b"}],
        removed: [],
        reset: false
      })
    end

    test "sends a stop the view removed as gone" do
      apply_one_route()
      view = open_ready()

      apply_stops([stop("a", %{route_ids: ["40_1"]})], %{route_id: "40_1", sequence: 5})

      assert_push_event(view, @event, %{stops: [%{id: "a"}], removed: ["b"], reset: false})
    end

    test "sends a changed stop that no drawn route serves as gone" do
      apply_one_route()
      view = open_ready()

      apply_stops(
        [stop("a", %{route_ids: ["40_1"]}), stop("b", %{route_ids: ["40_9"]})],
        %{route_id: "40_1", sequence: 5}
      )

      assert_push_event(view, @event, %{stops: [%{id: "a"}], removed: ["b"], reset: false})
    end
  end

  describe "a change of the lines drawn" do
    test "sends every stop again when a route's line appears" do
      apply_routes([{"40_1", "1 Line"}], %{agency_id: "40", sequence: 1})
      apply_stops([stop("a", %{route_ids: ["40_1"]})], %{route_id: "40_1", sequence: 2})
      view = open_page()
      ready(view)
      assert_push_event(view, @event, %{stops: [], reset: true})

      apply_path(%{route_id: "40_1", sequence: 2})

      assert_push_event(view, @event, %{stops: [%{id: "a"}], reset: true})
    end

    test "sends nothing when a route's line changes and no line appears or goes" do
      apply_one_route()
      view = open_ready()

      apply_path(%{route_id: "40_1", sequence: 6})

      refute_push_event(view, @event, %{}, @push_wait_ms)
    end
  end

  describe "the map's fit under a route filter" do
    @fit_event "basemap:fit"
    @route_bounds %{"south" => 47.6, "west" => -122.4, "north" => 47.7, "east" => -122.3}

    # Agency "40" lists a route whose two stops span `@route_bounds`, and
    # agency "1" a route with one stop elsewhere.
    setup do
      apply_routes([{"40_1", "1 Line"}], %{agency_id: "40", sequence: 1})
      apply_routes([{"1_44", "44"}], %{agency_id: "1", sequence: 2})
      apply_path(%{route_id: "40_1", sequence: 3})
      apply_path(%{route_id: "1_44", sequence: 4})

      apply_stops(
        [
          stop("a", %{route_ids: ["40_1"], lat: 47.6, lon: -122.3}),
          stop("b", %{route_ids: ["40_1"], lat: 47.7, lon: -122.4})
        ],
        %{route_id: "40_1", sequence: 3}
      )

      apply_stops([stop("c", %{route_ids: ["1_44"], lat: 47.2, lon: -122.9})], %{
        route_id: "1_44",
        sequence: 4
      })
    end

    defp fit_bounds(view) do
      [value] =
        view
        |> element("#basemap-basemap-20261004-01")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attribute("data-bounds")

      JSON.decode!(value)
    end

    test "is the box around the stops of the route the filter names" do
      assert fit_bounds(open_page("/vehicles?route=40_1")) == @route_bounds
    end

    test "is the box around the stops of every route the filter names" do
      assert fit_bounds(open_page("/vehicles?route=40_1,1_44")) ==
               %{"south" => 47.2, "west" => -122.9, "north" => 47.7, "east" => -122.3}
    end

    test "is the route's box under a filter that names its agency as well" do
      assert fit_bounds(open_page("/vehicles?agency=40&route=40_1")) == @route_bounds
    end

    test "is the whole archive for a route that has no stop" do
      assert fit_bounds(open_page("/vehicles?route=40_9")) == @bounds
    end

    test "is the whole archive for a route whose agency the filter leaves out" do
      assert fit_bounds(open_page("/vehicles?agency=1&route=40_1")) == @bounds
    end

    test "moves the map when the filter comes to name the route" do
      view = open_page()

      render_patch(view, "/vehicles?route=40_1")

      assert_push_event(view, @fit_event, %{
        bounds: %{south: 47.6, west: -122.4, north: 47.7, east: -122.3}
      })
    end

    test "leaves the map where it is when the route's stops change" do
      view = open_page("/vehicles?route=40_1")

      apply_stops([stop("a", %{route_ids: ["40_1"], lat: 47.1, lon: -122.1})], %{
        route_id: "40_1",
        sequence: 5
      })

      # A render waits for the page to have handled the announcement.
      render(view)
      refute_push_event(view, @fit_event, %{}, @push_wait_ms)
    end
  end
end
