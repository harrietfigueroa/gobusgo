defmodule GobusgoWeb.VehicleLiveFilterTest do
  # Mounts the vehicle page with Phoenix.LiveViewTest at addresses that
  # carry a filter, over a basemap manifest the test writes to its temporary
  # directory and the application's vehicle view, filled with the record
  # values VehicleBatch.Records builds. Both are global state, hence the
  # non-async case. The browser draws the markers, so these tests observe
  # the events that carry each agency's markers, the bounds the map is
  # handed, the notice of a refused filter, the controls, and the events the
  # page and the hook that stores the filter exchange.
  # The agency view and the route view fill the controls.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.Filter
  alias Gobusgo.OneBusAway.AgencyBatch
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RoutePathBatch
  alias Gobusgo.OneBusAway.VehicleBatch.Records
  alias Gobusgo.OneBusAway.VehicleView

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @event "vehicle-markers:agency"
  @store_event "vehicle-filter:store"
  @form "#vehicle-filter"
  @route_view Gobusgo.OneBusAway.RouteView
  @route_path_view Gobusgo.OneBusAway.RoutePathView
  @fetched_at ~U[2026-10-02 03:15:00Z]
  @archive_bounds %{"south" => 47.0, "west" => -123.0, "north" => 48.0, "east" => -122.0}
  @agency_bounds %{"south" => 47.4, "west" => -122.5, "north" => 47.8, "east" => -122.2}
  @map "#basemap-basemap-20261004-01"
  @manifest %{
    "snapshot" => "20261004",
    "archives" => [%{"name" => "basemap-20261004-01.pmtiles", "bounds" => @archive_bounds}],
    "agencies" => [
      %{"agencyId" => "1", "archive" => "basemap-20261004-01.pmtiles", "bounds" => @agency_bounds}
    ]
  }

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:gobusgo, :basemap)
    Application.put_env(:gobusgo, :basemap, dir: tmp_dir)
    File.write!(Path.join(tmp_dir, "manifest.json"), JSON.encode!(@manifest))
    restart_view()

    on_exit(fn ->
      Application.put_env(:gobusgo, :basemap, configured)
      restart_view()
    end)
  end

  defp restart_view do
    for view <- [AgencyView, VehicleView, @route_view, @route_path_view] do
      :ok = Supervisor.terminate_child(Gobusgo.Supervisor, view)
      {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, view)
    end
  end

  defp request_id(sequence) do
    "0199c4a2-7e1b-7a3f-9d20-" <> String.pad_leading(Integer.to_string(sequence), 12, "0")
  end

  # A vehicle is its identifier, or `{identifier, route identifier}` for one
  # on a route.
  defp vehicle({id, route_id}), do: %{vehicle(id) | route_id: route_id}

  defp vehicle(id) do
    %{
      id: id,
      active_trip_id: nil,
      route_id: nil,
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
      next_stop_time_offset_seconds: nil
    }
  end

  # Publishes a fetch of `agency_id`; `sequence` orders the fetches of a
  # test, as the request identifier and as seconds after the first fetch.
  defp apply_fetch(vehicles, %{agency_id: agency_id, sequence: sequence}) do
    %{vehicles: records, manifest: manifest} =
      Records.build(%{
        agency_id: agency_id,
        destination: "raw/oba/vehicles-for-agency/dt=2026-10-02/agency=#{agency_id}/file.json",
        fetched_at: DateTime.add(@fetched_at, sequence, :second),
        data_sha256: String.duplicate("ab", 32),
        request_id: request_id(sequence),
        vehicles: Enum.map(vehicles, &vehicle/1)
      })

    :ok = VehicleView.apply_records(VehicleView, Enum.map(records ++ [manifest], & &1.value))
  end

  # Publishes a fetch of agencies, each `{id, name}`; `sequence` orders the
  # fetches of a test.
  defp apply_agencies(agencies, sequence \\ 0) do
    %{agencies: records, manifest: manifest} =
      AgencyBatch.Records.build(%{
        destination: "raw/oba/agencies-with-coverage/dt=2026-10-02/file.json",
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

  # The agencies "1" and "40" in the agency view, and the page at `path`.
  defp open_with_agencies(path) do
    apply_agencies([{"40", "Sound Transit"}, {"1", "Metro Transit"}])
    {:ok, view, _html} = live(build_conn(), path)
    view
  end

  # The tokens of the filter bar in order, each `{field, value, name}`.
  defp tokens(view) do
    for token <- LazyHTML.query(form_document(view), "#vehicle-filter-tokens li") do
      [field] = LazyHTML.attribute(token, "data-field")
      [value] = LazyHTML.attribute(token, "data-value")
      name = token |> LazyHTML.query(".filter-token-name") |> LazyHTML.text() |> String.trim()
      {field, value, name}
    end
  end

  # The suggestions of the filter bar in order, each `{field, value, label}`,
  # a label's parts separated by one space, its kind first.
  defp suggestions(view) do
    for option <- LazyHTML.query(form_document(view), "#vehicle-filter-suggestions li") do
      [field] = LazyHTML.attribute(option, "phx-value-field")
      [value] = LazyHTML.attribute(option, "phx-value-id")
      text = Enum.map_join(LazyHTML.query(option, "span"), " ", &String.trim(LazyHTML.text(&1)))
      {field, value, text}
    end
  end

  defp input_value(view) do
    view
    |> form_document()
    |> LazyHTML.query("#vehicle-filter-input")
    |> LazyHTML.attribute("value")
  end

  defp form_document(view), do: view |> element(@form) |> render() |> LazyHTML.from_fragment()

  defp type(view, text), do: view |> form(@form, %{"filter_query" => text}) |> render_change()

  # Chooses the suggestion of `value` after typing `text`.
  defp choose(view, %{text: text, value: value}) do
    type(view, text)

    view
    |> element("#vehicle-filter-suggestions li[phx-value-id='#{value}']")
    |> render_click()
  end

  defp remove(view, value) do
    view |> element("#vehicle-filter-tokens button[phx-value-id='#{value}']") |> render_click()
  end

  defp supplied(view) do
    [value] =
      view
      |> element(@form)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("data-supplied")

    value
  end

  # Publishes a fetch of the routes `named_routes` of `agency_id`, each an
  # identifier or `{identifier, short name, long name}`, and a path of one
  # polyline for each.
  defp apply_routes(named_routes, %{agency_id: agency_id, sequence: sequence}) do
    named_routes =
      for named_route <- named_routes do
        case named_route do
          {_id, _short_name, _long_name} = named -> named
          id -> {id, nil, nil}
        end
      end

    route_ids = for {id, _short_name, _long_name} <- named_routes, do: id

    fetch = %{
      fetched_at: DateTime.add(@fetched_at, sequence, :second),
      data_sha256: String.duplicate("ab", 32),
      request_id: request_id(sequence)
    }

    routes =
      for {route_id, short_name, long_name} <- named_routes do
        %{
          id: route_id,
          agency_id: agency_id,
          short_name: short_name,
          long_name: long_name,
          description: nil,
          type: 3,
          color: nil,
          text_color: nil,
          url: nil
        }
      end

    record =
      RouteBatch.Records.build(
        Map.merge(fetch, %{
          agency_id: agency_id,
          destination: "raw/oba/routes-for-agency/dt=2026-10-05/agency=#{agency_id}/file.json.gz",
          routes: routes
        })
      )

    paths =
      for route_id <- route_ids do
        RoutePathBatch.Records.build(
          Map.merge(fetch, %{
            route_id: route_id,
            destination: "raw/oba/stops-for-route/dt=2026-10-05/route=#{route_id}/file.json.gz",
            route_path: %{
              route_id: route_id,
              stop_ids: [],
              polylines: [%{points: "mbpaHphuiVJVbhAn|F", point_count: 3, levels: nil}],
              stop_groupings: [],
              stops: []
            }
          })
        ).value
      end

    :ok = FetchView.apply_records(@route_path_view, paths)
    :ok = FetchView.apply_records(@route_view, [record.value])
  end

  # Two agencies with a vehicle each, and the page at `path` after its map
  # asked for the markers.
  defp open_ready(path) do
    apply_fetch(["1_a"], %{agency_id: "1", sequence: 1})
    apply_fetch(["40_x"], %{agency_id: "40", sequence: 2})
    {:ok, view, _html} = live(build_conn(), path)
    view |> element("#vehicle-markers") |> render_hook("vehicle-markers:ready")
    view
  end

  # Agency "1" with a vehicle on each of two routes and one on none, agency
  # "40" with a vehicle on a route, and the page at `path` after its map
  # asked for the markers.
  defp open_on_routes_ready(path) do
    apply_fetch([{"1_a", "1_100"}, {"1_b", "1_200"}, "1_c"], %{agency_id: "1", sequence: 1})
    apply_fetch([{"40_x", "40_500"}], %{agency_id: "40", sequence: 2})
    {:ok, view, _html} = live(build_conn(), path)
    view |> element("#vehicle-markers") |> render_hook("vehicle-markers:ready")
    view
  end

  defp bounds(view) do
    [value] =
      view
      |> element(@map)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("data-bounds")

    JSON.decode!(value)
  end

  describe "a page opened at an address with an agency filter" do
    test "sends the markers of the agency the filter names" do
      view = open_ready("/vehicles?agency=40")

      assert_push_event(view, @event, %{agency_id: "40", markers: [%{id: "40/40_x"}]})
    end

    test "sends no marker of an agency the filter leaves out" do
      view = open_ready("/vehicles?agency=40")

      refute_push_event(view, @event, %{agency_id: "1", markers: [_marker | _rest]})
    end

    test "sends the markers of every agency the filter names" do
      view = open_ready("/vehicles?agency=1,40")

      assert_push_event(view, @event, %{agency_id: "1", markers: [%{id: "1/1_a"}]})
      assert_push_event(view, @event, %{agency_id: "40", markers: [%{id: "40/40_x"}]})
    end

    test "sends no marker for an agency that no fetch is of, and shows no notice" do
      view = open_ready("/vehicles?agency=nope")

      refute_push_event(view, @event, %{markers: [_marker | _rest]})
      refute has_element?(view, "#filter-refused")
    end

    test "fits the map to the coverage of the one agency the filter names" do
      view = open_ready("/vehicles?agency=1")

      assert bounds(view) == @agency_bounds
    end

    test "fits the map to the whole archive for a filter that names two agencies" do
      view = open_ready("/vehicles?agency=1,40")

      assert bounds(view) == @archive_bounds
    end
  end

  describe "a page opened at an address with a route filter" do
    test "sends the markers of the vehicles on the route, and none on another or on no route" do
      view = open_on_routes_ready("/vehicles?route=1_100")

      assert_push_event(view, @event, %{agency_id: "1", markers: [%{id: "1/1_a"}]})
    end

    test "sends the markers of the vehicles on every route the filter names" do
      view = open_on_routes_ready("/vehicles?route=1_100,40_500")

      assert_push_event(view, @event, %{agency_id: "1", markers: [%{id: "1/1_a"}]})
      assert_push_event(view, @event, %{agency_id: "40", markers: [%{id: "40/40_x"}]})
    end

    test "sends no marker of an agency none of whose vehicles are on the route" do
      view = open_on_routes_ready("/vehicles?route=1_100")

      refute_push_event(view, @event, %{agency_id: "40", markers: [_marker | _rest]})
    end

    test "sends no marker for a route that no vehicle is on, and shows no notice" do
      view = open_on_routes_ready("/vehicles?route=1_999")

      refute_push_event(view, @event, %{markers: [_marker | _rest]})
      refute has_element?(view, "#filter-refused")
    end

    test "is marked as supplying a filter" do
      view = open_with_agencies("/vehicles?route=1_100")

      assert supplied(view) == "true"
    end

    test "fits the map to the whole archive" do
      view = open_on_routes_ready("/vehicles?route=1_100")

      assert bounds(view) == @archive_bounds
    end

    test "shows the notice for more routes than the limit" do
      routes = Enum.map_join(0..Filter.value_count_max(), ",", &"1_#{&1}")
      view = open_on_routes_ready("/vehicles?route=" <> routes)

      assert view |> element("#filter-refused") |> render() =~ "This filter is not valid."
    end

    test "sends no marker for more routes than the limit" do
      routes = Enum.map_join(0..Filter.value_count_max(), ",", &"1_#{&1}")
      view = open_on_routes_ready("/vehicles?route=" <> routes)

      refute_push_event(view, @event, %{markers: [_marker | _rest]})
    end
  end

  describe "a page opened at an address with a route and an agency filter" do
    test "sends the markers of the named agency's vehicles on the route" do
      view = open_on_routes_ready("/vehicles?agency=1&route=1_200")

      assert_push_event(view, @event, %{agency_id: "1", markers: [%{id: "1/1_b"}]})
    end

    test "sends no marker of a vehicle on the route whose agency the filter leaves out" do
      view = open_on_routes_ready("/vehicles?agency=1&route=40_500")

      refute_push_event(view, @event, %{markers: [_marker | _rest]})
    end

    test "fits the map to the coverage of the one agency the filter names" do
      view = open_on_routes_ready("/vehicles?agency=1&route=1_200")

      assert bounds(view) == @agency_bounds
    end
  end

  describe "a new fetch under a route filter" do
    test "sends the markers of its vehicles on the route" do
      view = open_on_routes_ready("/vehicles?route=1_100")

      apply_fetch([{"1_a", "1_100"}, {"1_d", "1_100"}, {"1_b", "1_200"}], %{
        agency_id: "1",
        sequence: 3
      })

      assert_push_event(view, @event, %{
        agency_id: "1",
        markers: [%{id: "1/1_a"}, %{id: "1/1_d"}]
      })
    end

    test "leaves out a vehicle that moved to another route" do
      view = open_on_routes_ready("/vehicles?route=1_100")
      assert_push_event(view, @event, %{agency_id: "1", markers: [%{id: "1/1_a"}]})

      apply_fetch([{"1_a", "1_200"}], %{agency_id: "1", sequence: 3})

      assert_push_event(view, @event, %{agency_id: "1", markers: []})
    end

    test "takes in a vehicle that moved onto the route" do
      view = open_on_routes_ready("/vehicles?route=1_100")
      assert_push_event(view, @event, %{agency_id: "1", markers: [%{id: "1/1_a"}]})

      apply_fetch([{"1_a", "1_100"}, {"1_b", "1_100"}], %{agency_id: "1", sequence: 3})

      assert_push_event(view, @event, %{
        agency_id: "1",
        markers: [%{id: "1/1_a"}, %{id: "1/1_b"}]
      })
    end

    test "leaves out a vehicle that lost its route" do
      view = open_on_routes_ready("/vehicles?route=1_100")
      assert_push_event(view, @event, %{agency_id: "1", markers: [%{id: "1/1_a"}]})

      apply_fetch(["1_a"], %{agency_id: "1", sequence: 3})

      assert_push_event(view, @event, %{agency_id: "1", markers: []})
    end
  end

  describe "a change of the address's route filter" do
    test "sends the markers of the vehicles on the new route" do
      view = open_on_routes_ready("/vehicles?route=1_100")
      assert_push_event(view, @event, %{agency_id: "1", markers: [%{id: "1/1_a"}]})

      render_patch(view, "/vehicles?route=1_200")

      assert_push_event(view, @event, %{agency_id: "1", markers: [%{id: "1/1_b"}]})
    end

    test "sends every vehicle's marker when the filter is removed" do
      view = open_on_routes_ready("/vehicles?route=1_100")
      assert_push_event(view, @event, %{agency_id: "1", markers: [%{id: "1/1_a"}]})

      render_patch(view, "/vehicles")

      assert_push_event(view, @event, %{
        agency_id: "1",
        markers: [%{id: "1/1_a"}, %{id: "1/1_b"}, %{id: "1/1_c"}]
      })
    end
  end

  describe "a new fetch under an agency filter" do
    test "sends the markers of an agency the filter names" do
      view = open_ready("/vehicles?agency=40")

      apply_fetch(["40_y"], %{agency_id: "40", sequence: 3})

      assert_push_event(view, @event, %{agency_id: "40", markers: [%{id: "40/40_y"}]})
    end

    test "sends nothing for an agency the filter leaves out" do
      view = open_ready("/vehicles?agency=40")
      assert_push_event(view, @event, %{agency_id: "40"})

      apply_fetch(["1_b"], %{agency_id: "1", sequence: 3})
      apply_fetch(["40_y"], %{agency_id: "40", sequence: 4})

      assert_push_event(view, @event, %{agency_id: "40", markers: [%{id: "40/40_y"}]})
      refute_push_event(view, @event, %{agency_id: "1", markers: [_marker | _rest]})
    end
  end

  describe "a change of the address's filter" do
    test "sends the markers of an agency the new filter adds" do
      view = open_ready("/vehicles?agency=40")

      render_patch(view, "/vehicles?agency=1")

      assert_push_event(view, @event, %{agency_id: "1", markers: [%{id: "1/1_a"}]})
    end

    test "sends an agency the new filter leaves out with no marker" do
      view = open_ready("/vehicles?agency=40")

      render_patch(view, "/vehicles?agency=1")

      assert_push_event(view, @event, %{agency_id: "40", markers: []})
    end

    test "sends every agency's markers when the filter is removed" do
      view = open_ready("/vehicles?agency=40")

      render_patch(view, "/vehicles")

      assert_push_event(view, @event, %{agency_id: "1", markers: [%{id: "1/1_a"}]})
    end

    test "sends nothing when the filter stays the same" do
      view = open_ready("/vehicles?agency=1,40")
      assert_push_event(view, @event, %{agency_id: "1"})
      assert_push_event(view, @event, %{agency_id: "40"})

      render_patch(view, "/vehicles?agency=40,1")

      refute_push_event(view, @event, %{})
    end
  end

  describe "a page opened at an address with a refused filter" do
    for {description, query} <- [
          {"a field that holds a map", "agency[x]=1"},
          {"more values than the limit",
           "agency=" <> Enum.map_join(0..Filter.value_count_max(), ",", &Integer.to_string/1)}
        ] do
      test "shows the notice for #{description}" do
        view = open_ready("/vehicles?" <> unquote(query))

        assert view |> element("#filter-refused") |> render() =~ "This filter is not valid."
      end

      test "sends no marker for #{description}" do
        view = open_ready("/vehicles?" <> unquote(query))

        refute_push_event(view, @event, %{markers: [_marker | _rest]})
      end
    end

    test "links to the page without a filter" do
      view = open_ready("/vehicles?agency[x]=1")

      view |> element("#filter-refused a") |> render_click()

      assert_patch(view, "/vehicles")
      refute has_element?(view, "#filter-refused")
    end

    test "sends no marker of a new fetch" do
      view = open_ready("/vehicles?agency[x]=1")

      apply_fetch(["1_b"], %{agency_id: "1", sequence: 3})

      refute_push_event(view, @event, %{markers: [_marker | _rest]})
    end

    test "draws the map of the whole archive" do
      view = open_ready("/vehicles?agency[x]=1")

      assert bounds(view) == @archive_bounds
    end
  end

  describe "a page opened at an address without a filter" do
    test "shows no notice" do
      view = open_ready("/vehicles")

      refute has_element?(view, "#filter-refused")
    end
  end

  describe "the filter bar's tokens" do
    test "are none at an address without a filter" do
      view = open_with_agencies("/vehicles")

      assert tokens(view) == []
    end

    test "name the agencies the address's filter names by the agency view's names" do
      view = open_with_agencies("/vehicles?agency=40,1")

      assert tokens(view) == [
               {"agency", "1", "Metro Transit"},
               {"agency", "40", "Sound Transit"}
             ]
    end

    test "name an agency the agency view does not hold by its identifier" do
      view = open_with_agencies("/vehicles?agency=97")

      assert tokens(view) == [{"agency", "97", "97"}]
    end

    test "name the routes after the agencies, by the route view's names" do
      apply_routes([{"1_8", "8", nil}], %{agency_id: "1", sequence: 1})
      view = open_with_agencies("/vehicles?agency=1&route=1_8")

      assert tokens(view) == [{"agency", "1", "Metro Transit"}, {"route", "1_8", "8"}]
    end

    test "name a route the route view does not hold by its identifier" do
      view = open_with_agencies("/vehicles?route=1_999")

      assert tokens(view) == [{"route", "1_999", "1_999"}]
    end

    test "are none for a refused filter" do
      view = open_with_agencies("/vehicles?route=1_8&agency[x]=1")

      assert tokens(view) == []
    end

    test "follow a new fetch of the agency view" do
      view = open_with_agencies("/vehicles?agency=40")

      apply_agencies([{"40", "ST Express"}], 1)

      assert tokens(view) == [{"agency", "40", "ST Express"}]
    end

    test "label each remove button with its kind and name" do
      view = open_with_agencies("/vehicles?agency=40")

      assert has_element?(
               view,
               "#vehicle-filter-tokens button[aria-label='Remove agency Sound Transit']"
             )
    end

    test "are absent from a page with no basemap", %{tmp_dir: tmp_dir} do
      File.rm!(Path.join(tmp_dir, "manifest.json"))
      view = open_with_agencies("/vehicles")

      refute has_element?(view, @form)
    end
  end

  describe "the filter bar's suggestions" do
    # Agency "1" lists the routes 8 and 40 and agency "40" the routes 40 and
    # 550, and the page is at `path`.
    defp open_with_routes(path) do
      apply_routes([{"1_40", "40", "Ballard - Northgate"}, {"1_8", "8", nil}], %{
        agency_id: "1",
        sequence: 1
      })

      apply_routes([{"40_550", "550", nil}, {"40_40", "40", nil}], %{agency_id: "40", sequence: 2})

      open_with_agencies(path)
    end

    test "are none before text is typed" do
      view = open_with_routes("/vehicles")

      assert suggestions(view) == []
    end

    test "leave the combobox collapsed before text is typed" do
      view = open_with_routes("/vehicles")

      assert has_element?(view, "#vehicle-filter-input[aria-expanded='false']")
    end

    test "offer the agencies whose name holds the typed text, labeled as agencies" do
      view = open_with_routes("/vehicles")

      type(view, "sound")

      assert suggestions(view) == [{"agency", "40", "Agency Sound Transit"}]
    end

    test "offer the routes whose name holds the typed text, labeled as routes" do
      view = open_with_routes("/vehicles")

      type(view, "40")

      assert suggestions(view) == [
               {"route", "1_40", "Route 40 Ballard - Northgate Metro Transit"},
               {"route", "40_40", "Route 40 Sound Transit"}
             ]
    end

    test "mark the combobox as expanded while there are suggestions" do
      view = open_with_routes("/vehicles")

      type(view, "40")

      assert has_element?(view, "#vehicle-filter-input[aria-expanded='true']")
    end

    test "offer the routes of the agencies the filter names alone" do
      view = open_with_routes("/vehicles?agency=40")

      type(view, "40")

      assert suggestions(view) == [{"route", "40_40", "Route 40 Sound Transit"}]
    end

    test "leave out an agency the filter names" do
      view = open_with_routes("/vehicles?agency=40")

      type(view, "s")

      assert suggestions(view) == [{"agency", "1", "Agency Metro Transit"}]
    end

    test "leave out a route the filter names" do
      view = open_with_routes("/vehicles?agency=40&route=40_550")

      type(view, "5")

      assert suggestions(view) == []
    end

    test "say how many are left out" do
      count = GobusgoWeb.RouteOptions.match_count_max() + 2
      routes = for number <- 1..count, do: {"1_#{number}", "x#{number}", nil}
      apply_routes(routes, %{agency_id: "1", sequence: 1})
      view = open_with_agencies("/vehicles")

      type(view, "x")

      assert view |> element("#vehicle-filter-rest") |> render() =~ "2 more"
    end

    test "follow a new fetch of the route view" do
      view = open_with_routes("/vehicles?agency=40")
      type(view, "56")

      apply_routes([{"40_560", "560", nil}], %{agency_id: "40", sequence: 3})

      assert suggestions(view) == [{"route", "40_560", "Route 560 Sound Transit"}]
    end

    test "leave the address and the stored filter as they are while text is typed" do
      view = open_with_routes("/vehicles?route=1_8")

      type(view, "55")

      refute_push_event(view, @store_event, %{})
      refute_patched(view)
    end
  end

  describe "choosing a suggestion" do
    defp open_with_listed_routes(path) do
      apply_routes(["1_100"], %{agency_id: "1", sequence: 1})
      apply_routes(["40_500"], %{agency_id: "40", sequence: 2})
      open_with_agencies(path)
    end

    test "puts an agency into the address" do
      view = open_with_agencies("/vehicles")

      choose(view, %{text: "sound", value: "40"})

      assert_patch(view, "/vehicles?agency=40")
    end

    test "adds an agency to the agencies of the address's filter" do
      view = open_with_agencies("/vehicles?agency=40")

      choose(view, %{text: "metro", value: "1"})

      assert_patch(view, "/vehicles?agency=1,40")
    end

    test "adds a route to the routes of the address's filter" do
      view = open_with_listed_routes("/vehicles?route=1_100")

      choose(view, %{text: "40_5", value: "40_500"})

      assert_patch(view, "/vehicles?route=1_100,40_500")
    end

    test "has the browser store the filter" do
      view = open_with_listed_routes("/vehicles?agency=40")

      choose(view, %{text: "40_5", value: "40_500"})

      assert_push_event(view, @store_event, %{
        filter: %{"agency" => ["40"], "route" => ["40_500"]}
      })
    end

    test "shows the chosen value as a token" do
      view = open_with_agencies("/vehicles")

      choose(view, %{text: "sound", value: "40"})

      assert tokens(view) == [{"agency", "40", "Sound Transit"}]
    end

    test "clears the suggestions" do
      view = open_with_agencies("/vehicles")

      choose(view, %{text: "sound", value: "40"})

      assert suggestions(view) == []
    end

    test "clears the text" do
      view = open_with_agencies("/vehicles")

      choose(view, %{text: "sound", value: "40"})

      assert input_value(view) == [""]
    end

    test "sends the markers the new filter keeps" do
      apply_agencies([{"40", "Sound Transit"}, {"1", "Metro Transit"}])
      view = open_ready("/vehicles")

      choose(view, %{text: "sound", value: "40"})

      assert_push_event(view, @event, %{agency_id: "1", markers: []})
    end

    test "of an agency reduces the routes of the address's filter to those it lists" do
      view = open_with_listed_routes("/vehicles?route=40_500,1_100")

      choose(view, %{text: "sound", value: "40"})

      assert_patch(view, "/vehicles?agency=40&route=40_500")
    end

    test "of an agency keeps the routes that any of the filter's agencies lists" do
      view = open_with_listed_routes("/vehicles?agency=1&route=1_100")

      choose(view, %{text: "sound", value: "40"})

      assert_patch(view, "/vehicles?agency=1,40&route=1_100")
    end

    test "of an agency removes the routes when the agencies list none of them" do
      view = open_with_listed_routes("/vehicles?route=1_100")

      choose(view, %{text: "sound", value: "40"})

      assert_patch(view, "/vehicles?agency=40")
    end

    test "of an agency removes a route that no fetch of the route view lists" do
      view = open_with_agencies("/vehicles?route=40_500")

      choose(view, %{text: "sound", value: "40"})

      assert_patch(view, "/vehicles?agency=40")
    end

    test "has the browser store the filter with the reduced routes" do
      view = open_with_listed_routes("/vehicles?route=40_500,1_100")

      choose(view, %{text: "sound", value: "40"})

      assert_push_event(view, @store_event, %{
        filter: %{"agency" => ["40"], "route" => ["40_500"]}
      })
    end

    test "changes nothing for more routes than the limit" do
      routes = Enum.map_join(1..Filter.value_count_max(), ",", &"1_#{&1}")
      view = open_with_listed_routes("/vehicles?route=" <> routes)

      render_click(view, "vehicle-filter:add", %{"field" => "route", "id" => "1_100"})

      refute_push_event(view, @store_event, %{})
      refute_patched(view)
    end

    test "changes nothing for a field the filter does not know" do
      view = open_with_agencies("/vehicles?agency=40")

      render_click(view, "vehicle-filter:add", %{"field" => "color", "id" => "red"})

      refute_push_event(view, @store_event, %{})
      assert tokens(view) == [{"agency", "40", "Sound Transit"}]
    end

    test "changes nothing for parameters that name no field" do
      view = open_with_agencies("/vehicles?agency=40")

      render_click(view, "vehicle-filter:add", %{"id" => "1"})

      refute_push_event(view, @store_event, %{})
    end

    test "is shown again by a page that connects at the address it left" do
      view = open_with_listed_routes("/vehicles")
      choose(view, %{text: "40_5", value: "40_500"})
      path = assert_patch(view)

      {:ok, again, _html} = live(build_conn(), path)

      assert tokens(again) == [{"route", "40_500", "40_500"}]
      assert supplied(again) == "true"
    end
  end

  describe "removing a token" do
    test "removes its route from the address" do
      view = open_with_agencies("/vehicles?route=1_100,40_500")

      remove(view, "1_100")

      assert_patch(view, "/vehicles?route=40_500")
    end

    test "removes the route field with the last route" do
      view = open_with_agencies("/vehicles?agency=1&route=1_100")

      remove(view, "1_100")

      assert_patch(view, "/vehicles?agency=1")
    end

    test "keeps every route of the address's filter with the last agency" do
      view = open_with_agencies("/vehicles?agency=40&route=40_500")

      remove(view, "40")

      assert_patch(view, "/vehicles?route=40_500")
    end

    test "removes the filter from the address with the last token" do
      view = open_with_agencies("/vehicles?agency=40")

      remove(view, "40")

      assert_patch(view, "/vehicles")
      assert_push_event(view, @store_event, %{filter: filter})
      assert filter == %{}
    end

    test "sends the markers the new filter keeps" do
      apply_agencies([{"40", "Sound Transit"}, {"1", "Metro Transit"}])
      view = open_ready("/vehicles?agency=40")

      remove(view, "40")

      assert_push_event(view, @event, %{agency_id: "1", markers: [%{id: "1/1_a"}]})
    end

    test "leaves the typed text as it is" do
      view = open_with_agencies("/vehicles?agency=40")
      type(view, "metro")

      remove(view, "40")

      assert {"agency", "1", "Agency Metro Transit"} in suggestions(view)
    end

    test "changes nothing for parameters that name no field" do
      view = open_with_agencies("/vehicles?agency=40")

      render_click(view, "vehicle-filter:remove", %{})

      refute_push_event(view, @store_event, %{})
      assert tokens(view) == [{"agency", "40", "Sound Transit"}]
    end
  end

  describe "a filter the address supplies" do
    test "is marked as supplied, and the browser is not told to store it" do
      view = open_with_agencies("/vehicles?agency=40")

      assert supplied(view) == "true"
      refute_push_event(view, @store_event, %{})
    end

    test "is marked as supplied when it is blank" do
      view = open_with_agencies("/vehicles?agency=")

      assert supplied(view) == "true"
    end

    test "stays when the browser offers a stored filter" do
      view = open_with_agencies("/vehicles?agency=40")

      view
      |> element(@form)
      |> render_hook("vehicle-filter:restore", %{"filter" => %{"agency" => ["1"]}})

      assert tokens(view) == [{"agency", "40", "Sound Transit"}]
    end
  end

  describe "a stored filter the browser offers at an address without a filter" do
    test "is not marked as supplied by the address" do
      view = open_with_agencies("/vehicles")

      assert supplied(view) == "false"
    end

    test "goes into the address" do
      view = open_with_agencies("/vehicles")

      view
      |> element(@form)
      |> render_hook("vehicle-filter:restore", %{"filter" => %{"agency" => ["40", "1"]}})

      assert_patch(view, "/vehicles?agency=1,40")
      assert_reply(view, %{accepted: true})
    end

    test "goes into the address with the routes it names" do
      view = open_with_agencies("/vehicles")

      view
      |> element(@form)
      |> render_hook("vehicle-filter:restore", %{"filter" => %{"route" => ["40_500"]}})

      assert_patch(view, "/vehicles?route=40_500")
      assert_reply(view, %{accepted: true})
    end

    for {description, params} <- [
          {"a refused filter", %{"filter" => %{"color" => ["red"]}}},
          {"a filter that is no map", %{"filter" => "agency=1"}},
          {"no filter", %{}}
        ] do
      test "is turned down for #{description}, and the page keeps its filter" do
        view = open_with_agencies("/vehicles")

        view
        |> element(@form)
        |> render_hook("vehicle-filter:restore", unquote(Macro.escape(params)))

        assert_reply(view, %{accepted: false})
        refute has_element?(view, "#filter-refused")
        assert tokens(view) == []
      end
    end
  end

  describe "a page that connects again at the address a change left" do
    test "shows the same filter" do
      view = open_with_agencies("/vehicles")
      choose(view, %{text: "sound", value: "40"})
      path = assert_patch(view)

      {:ok, again, _html} = live(build_conn(), path)

      assert tokens(again) == [{"agency", "40", "Sound Transit"}]
      assert supplied(again) == "true"
    end
  end
end
