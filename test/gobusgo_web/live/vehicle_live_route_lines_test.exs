defmodule GobusgoWeb.VehicleLiveRouteLinesTest do
  # Mounts the vehicle page with Phoenix.LiveViewTest over a basemap manifest
  # the test writes to its temporary directory and the application's agency
  # view and two route views, filled with the record values their records
  # modules build.
  # All are global state, hence the non-async case. The browser draws the
  # lines, so these tests observe what the page hands it: the events that
  # carry the routes' lines, and the element the line hook mounts on.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.OneBusAway.AgencyBatch
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RoutePathBatch
  alias GobusgoWeb.RouteLines

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @event "route-lines:routes"
  @push_wait_ms 50
  @route_view Gobusgo.OneBusAway.RouteView
  @route_path_view Gobusgo.OneBusAway.RoutePathView
  @fetched_at ~U[2026-10-05 01:00:00Z]
  @points "mbpaHphuiVJVbhAn|F"
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
    for view <- [AgencyView, @route_view, @route_path_view] do
      :ok = Supervisor.terminate_child(Gobusgo.Supervisor, view)
      {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, view)
    end
  end

  defp request_id(sequence) do
    "0199c4a2-7e1b-7a3f-9d20-" <> String.pad_leading(Integer.to_string(sequence), 12, "0")
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

  # A route is `{id, color}`, or `{id, color, names}` for one that has a
  # short name or a long name.
  defp route_names({id, color}), do: {id, color, %{}}
  defp route_names({id, color, names}), do: {id, color, names}

  # Publishes a fetch of the routes of `agency_id`; `sequence` orders the
  # fetches of a test.
  defp apply_routes(routes, %{agency_id: agency_id, sequence: sequence}) do
    record =
      RouteBatch.Records.build(%{
        agency_id: agency_id,
        destination: "raw/oba/routes-for-agency/dt=2026-10-05/agency=#{agency_id}/file.json.gz",
        fetched_at: DateTime.add(@fetched_at, sequence, :second),
        data_sha256: String.duplicate("ab", 32),
        request_id: request_id(sequence),
        routes:
          for {id, color, names} <- Enum.map(routes, &route_names/1) do
            %{
              id: id,
              agency_id: agency_id,
              short_name: Map.get(names, :short_name),
              long_name: Map.get(names, :long_name),
              description: nil,
              type: 3,
              color: color,
              text_color: nil,
              url: nil
            }
          end
      })

    :ok = FetchView.apply_records(@route_view, [record.value])
  end

  # Publishes a fetch of the path of `route_id` with the given polylines.
  defp apply_path(points, %{route_id: route_id, sequence: sequence}) do
    record =
      RoutePathBatch.Records.build(%{
        route_id: route_id,
        destination: "raw/oba/stops-for-route/dt=2026-10-05/route=#{route_id}/file.json.gz",
        fetched_at: DateTime.add(@fetched_at, sequence, :second),
        data_sha256: String.duplicate("ab", 32),
        request_id: request_id(sequence),
        route_path: %{
          route_id: route_id,
          stop_ids: [],
          polylines: for(text <- points, do: %{points: text, point_count: 3, levels: nil}),
          stop_groupings: [],
          stops: []
        }
      })

    :ok = FetchView.apply_records(@route_path_view, [record.value])
  end

  defp open_page do
    {:ok, view, _html} = live(build_conn(), "/vehicles")
    view
  end

  defp ready(view), do: view |> element("#route-lines") |> render_hook("route-lines:ready")

  describe "the page" do
    test "holds the element the line hook mounts on, shown as nothing" do
      html = open_page() |> element("#route-lines") |> render()

      assert html =~ ~s(phx-hook="RouteLines")
      assert html =~ "hidden"
    end

    test "holds no line element when there is no basemap", %{tmp_dir: tmp_dir} do
      File.rm!(Path.join(tmp_dir, "manifest.json"))

      refute open_page() |> has_element?("#route-lines")
    end
  end

  describe "the lines' ready event" do
    test "is answered with the line of every route of every agency, in identifier order" do
      apply_routes([{"40_1", "28813F"}], %{agency_id: "40", sequence: 1})
      apply_routes([{"1_1", "FDB71A"}], %{agency_id: "1", sequence: 2})
      apply_path([@points, "}xmaHxf}iVchAo|FKW"], %{route_id: "40_1", sequence: 3})
      apply_path([@points], %{route_id: "1_1", sequence: 4})
      view = open_page()

      ready(view)

      assert_push_event(view, @event, %{lines: lines, removed: []})

      assert [
               %{id: "1_1", color: "#FDB71A", polylines: [@points]},
               %{id: "40_1", color: "#28813F", polylines: [@points, "}xmaHxf}iVchAo|FKW"]}
             ] = lines
    end

    test "is answered with each route's names and its agency's name" do
      apply_agencies([{"40", "Sound Transit"}], 1)
      names = %{short_name: "1 Line", long_name: "Lynnwood - Federal Way"}
      apply_routes([{"40_1", "28813F", names}], %{agency_id: "40", sequence: 2})
      apply_path([@points], %{route_id: "40_1", sequence: 3})
      view = open_page()

      ready(view)

      assert_push_event(view, @event, %{lines: [line]})

      assert line == %{
               id: "40_1",
               color: "#28813F",
               short_name: "1 Line",
               long_name: "Lynnwood - Federal Way",
               agency_name: "Sound Transit",
               polylines: [@points]
             }
    end

    test "is answered with no name for a route that has none, of an agency the view lacks" do
      apply_routes([{"40_1", nil}], %{agency_id: "40", sequence: 1})
      apply_path([@points], %{route_id: "40_1", sequence: 2})
      view = open_page()

      ready(view)

      assert_push_event(view, @event, %{
        lines: [%{id: "40_1", short_name: nil, long_name: nil, agency_name: nil}]
      })
    end

    test "is answered with the default color for a route that has none" do
      apply_routes([{"40_1", nil}], %{agency_id: "40", sequence: 1})
      apply_path([@points], %{route_id: "40_1", sequence: 2})
      view = open_page()

      ready(view)

      default_color = RouteLines.default_color()
      assert_push_event(view, @event, %{lines: [%{id: "40_1", color: ^default_color}]})
    end

    test "is answered with a line without polylines for a route whose path has none" do
      apply_routes([{"40_1", nil}], %{agency_id: "40", sequence: 1})
      apply_path([], %{route_id: "40_1", sequence: 2})
      view = open_page()

      ready(view)

      assert_push_event(view, @event, %{lines: [%{id: "40_1", polylines: []}]})
    end

    test "leaves out a route that has no path yet" do
      apply_routes([{"40_1", nil}, {"40_2", nil}], %{agency_id: "40", sequence: 1})
      apply_path([@points], %{route_id: "40_1", sequence: 2})
      view = open_page()

      ready(view)

      assert_push_event(view, @event, %{lines: [%{id: "40_1"}]})
    end

    test "is answered with several events when the lines are more than one holds" do
      count = RouteLines.event_line_count_max() + 1
      route_ids = for index <- 1..count, do: "40_" <> String.pad_leading("#{index}", 3, "0")
      apply_routes(Enum.map(route_ids, &{&1, nil}), %{agency_id: "40", sequence: 1})

      for {route_id, index} <- Enum.with_index(route_ids, 2) do
        apply_path([@points], %{route_id: route_id, sequence: index})
      end

      view = open_page()

      ready(view)

      assert_push_event(view, @event, %{lines: [%{id: "40_001"} | _rest] = first})
      assert_push_event(view, @event, %{lines: [%{id: last_id}]})
      assert length(first) == RouteLines.event_line_count_max()
      assert last_id == List.last(route_ids)
    end

    test "is answered with no event before any route has a path" do
      apply_routes([{"40_1", nil}], %{agency_id: "40", sequence: 1})
      view = open_page()

      ready(view)

      refute_push_event(view, @event, _payload, @push_wait_ms)
    end
  end

  describe "a switch of a route view" do
    setup do
      apply_routes([{"40_1", "28813F"}, {"40_2", nil}], %{agency_id: "40", sequence: 1})
      apply_path([@points], %{route_id: "40_1", sequence: 2})
      apply_path([@points], %{route_id: "40_2", sequence: 3})
      view = open_page()
      ready(view)
      assert_push_event(view, @event, %{lines: [_first, _second]})
      %{view: view}
    end

    test "sends the line of the route whose path is newer, and no other", %{view: view} do
      apply_path(["}xmaHxf}iVchAo|FKW"], %{route_id: "40_2", sequence: 4})

      assert_push_event(view, @event, %{lines: lines, removed: []})

      default_color = RouteLines.default_color()

      assert [%{id: "40_2", color: ^default_color, polylines: ["}xmaHxf}iVchAo|FKW"]}] = lines
    end

    test "sends the line of a route of which only a name changed, and no other", %{view: view} do
      apply_routes([{"40_1", "28813F"}, {"40_2", nil, %{short_name: "2 Line"}}], %{
        agency_id: "40",
        sequence: 4
      })

      assert_push_event(view, @event, %{lines: lines, removed: []})
      assert [%{id: "40_2", short_name: "2 Line", polylines: [@points]}] = lines
    end

    test "sends the line of a route whose color changed", %{view: view} do
      apply_routes([{"40_1", "28813F"}, {"40_2", "FFFFFF"}], %{agency_id: "40", sequence: 4})

      assert_push_event(view, @event, %{lines: [%{id: "40_2", color: "#FFFFFF"}], removed: []})
    end

    test "sends the line of a route whose path arrives after the page opened", %{view: view} do
      apply_routes([{"40_1", "28813F"}, {"40_2", nil}, {"40_3", nil}], %{
        agency_id: "40",
        sequence: 4
      })

      refute_push_event(view, @event, _payload, @push_wait_ms)

      apply_path([@points], %{route_id: "40_3", sequence: 5})

      assert_push_event(view, @event, %{lines: [%{id: "40_3"}], removed: []})
    end

    test "names a route its agency no longer lists as removed", %{view: view} do
      apply_routes([{"40_1", "28813F"}], %{agency_id: "40", sequence: 4})

      assert_push_event(view, @event, %{lines: [], removed: ["40_2"]})
    end

    test "sends nothing for a fetch that changes no line", %{view: view} do
      apply_routes([{"40_1", "28813F"}, {"40_2", nil}], %{agency_id: "40", sequence: 4})

      refute_push_event(view, @event, _payload, @push_wait_ms)
    end
  end

  describe "a switch of the agency view" do
    setup do
      apply_agencies([{"40", "Sound Transit"}, {"1", "Metro Transit"}], 1)
      apply_routes([{"40_1", nil}], %{agency_id: "40", sequence: 2})
      apply_routes([{"1_1", nil}], %{agency_id: "1", sequence: 3})
      apply_path([@points], %{route_id: "40_1", sequence: 4})
      apply_path([@points], %{route_id: "1_1", sequence: 5})
      view = open_page()
      ready(view)
      assert_push_event(view, @event, %{lines: [_first, _second]})
      %{view: view}
    end

    test "sends the lines of the agency whose name changed, and no other", %{view: view} do
      apply_agencies([{"40", "Sound Transit Express"}, {"1", "Metro Transit"}], 6)

      assert_push_event(view, @event, %{lines: lines, removed: []})
      assert [%{id: "40_1", agency_name: "Sound Transit Express"}] = lines
    end

    test "sends nothing when no agency's name changed", %{view: view} do
      apply_agencies([{"40", "Sound Transit"}, {"1", "Metro Transit"}], 6)

      refute_push_event(view, @event, _payload, @push_wait_ms)
    end
  end
end
