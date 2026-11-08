defmodule GobusgoWeb.VehicleLivePanelSheetTest do
  # Mounts the vehicle page with Phoenix.LiveViewTest over a basemap manifest
  # the test writes to its temporary directory, with the agency view, the
  # route view, and the vehicle situation view filled with the record values
  # their records modules build. All are global state, hence the non-async
  # case. The browser opens the tabs and drags the sheet, so these tests
  # observe what the server renders: the tabs, the panel each one controls,
  # what each panel holds, the badges, the summary of the filter, and the
  # attributes a patch leaves to the browser.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.OneBusAway.AgencyBatch
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.VehicleBatch

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @sheet "#panel-sheet"
  @route_view Gobusgo.OneBusAway.RouteView
  @vehicle_situation_view Gobusgo.OneBusAway.VehicleSituationView
  @fetched_at ~U[2026-10-02 03:15:00Z]
  @bounds %{"south" => 47.0, "west" => -123.0, "north" => 48.0, "east" => -122.0}
  @manifest %{
    "snapshot" => "20261004",
    "archives" => [%{"name" => "basemap-20261004-01.pmtiles", "bounds" => @bounds}],
    "agencies" => []
  }
  @tabs [
    {"trip", "Trip"},
    {"favorites", "Favorites"},
    {"filter", "Filter"},
    {"alerts", "Alerts"},
    {"about", "About"}
  ]

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:gobusgo, :basemap)
    Application.put_env(:gobusgo, :basemap, dir: tmp_dir)
    restart_views()

    on_exit(fn ->
      Application.put_env(:gobusgo, :basemap, configured)
      restart_views()
    end)
  end

  defp restart_views do
    for view <- [AgencyView, @route_view, @vehicle_situation_view] do
      :ok = Supervisor.terminate_child(Gobusgo.Supervisor, view)
      {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, view)
    end
  end

  defp write_manifest(%{tmp_dir: tmp_dir}) do
    File.write!(Path.join(tmp_dir, "manifest.json"), JSON.encode!(@manifest))
  end

  defp request_id(sequence) do
    "0199c4a2-7e1b-7a3f-9d20-" <> String.pad_leading(Integer.to_string(sequence), 12, "0")
  end

  defp apply_agencies(agencies) do
    %{agencies: records, manifest: manifest} =
      AgencyBatch.Records.build(%{
        destination: "raw/oba/agencies-with-coverage/dt=2026-10-02/file.json",
        fetched_at: @fetched_at,
        data_sha256: String.duplicate("ab", 32),
        request_id: request_id(1),
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

  # Publishes the routes of agency 1, each `{id, short name}`.
  defp apply_routes(routes) do
    record =
      RouteBatch.Records.build(%{
        agency_id: "1",
        request_id: request_id(2),
        fetched_at: @fetched_at,
        data_sha256: String.duplicate("ab", 32),
        destination: "raw/oba/routes-for-agency/dt=2026-10-02/agency=1/file.json.gz",
        routes:
          for {id, short_name} <- routes do
            %{
              id: id,
              agency_id: "1",
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

  # Publishes `count` current alerts of route 1_100479.
  defp apply_current_alerts(count) do
    now = DateTime.truncate(DateTime.utc_now(), :second)

    situations =
      for index <- 1..count//1 do
        %{
          id: "1_#{index}",
          summary: "Alert #{index}.",
          description: nil,
          url: nil,
          reason: "MAINTENANCE",
          creation_time_ms: 1_792_080_593_599 + index,
          active_windows: [],
          affects: [%{agency_id: "1", route_id: "1_100479", stop_id: nil}]
        }
      end

    record =
      VehicleBatch.SituationRecords.build(%{
        agency_id: "1",
        request_id: request_id(3),
        fetched_at: now,
        data_sha256: String.duplicate("ab", 32),
        destination: "raw/oba/example/dt=2026-10-15/file.json.gz",
        situations: situations
      })

    :ok = FetchView.apply_records(@vehicle_situation_view, [record.value])
  end

  defp fragment(view, selector) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment()
  end

  defp attribute(view, selector, name) do
    [value] = view |> fragment(selector) |> LazyHTML.attribute(name)
    value
  end

  defp text(view, selector) do
    view |> fragment(selector) |> LazyHTML.text() |> String.split() |> Enum.join(" ")
  end

  # The parts of the summary line, each one span.
  defp summary_parts(view) do
    view
    |> fragment("#panel-sheet-summary")
    |> LazyHTML.query("p > span")
    |> Enum.map(&LazyHTML.text/1)
  end

  defp tab_labels(view) do
    view
    |> fragment(@sheet <> " [role=tablist]")
    |> LazyHTML.query("[role=tab] [data-tab-label]")
    |> Enum.map(&LazyHTML.text/1)
  end

  describe "with a basemap" do
    setup :write_manifest

    test "offers the tabs Trip, Favorites, Filter, Alerts, and About, in that order" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert tab_labels(view) == Enum.map(@tabs, &elem(&1, 1))
    end

    for {tab, _label} <- @tabs do
      test "gives the #{tab} tab a panel it controls and that it labels" do
        {:ok, view, _html} = live(build_conn(), "/vehicles")
        tab_selector = "#panel-tab-#{unquote(tab)}"

        panel_id = attribute(view, tab_selector, "aria-controls")

        assert has_element?(view, "##{panel_id}[role=tabpanel]")
        assert attribute(view, "#" <> panel_id, "aria-labelledby") == "panel-tab-#{unquote(tab)}"
      end
    end

    test "opens collapsed on the Trip tab" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert attribute(view, @sheet, "data-expanded") == "false"
      assert attribute(view, "#panel-tab-trip", "aria-selected") == "true"
      assert attribute(view, "#panel-tab-filter", "aria-selected") == "false"
      refute has_element?(view, "#panel-trip[hidden]")
      assert has_element?(view, "#panel-filter[hidden]")
    end

    test "leaves the open tab and the sheet's state to the browser across patches" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      for {selector, attributes} <- [
            {@sheet, ["data-expanded"]},
            {"#panel-sheet-handle", ["aria-expanded", "aria-label"]},
            {"#panel-tab-trip", ["aria-selected", "tabindex"]},
            {"#panel-trip", ["hidden"]}
          ] do
        commands = view |> attribute(selector, "phx-mounted") |> JSON.decode!()
        assert [["ignore_attrs", %{"attrs" => ^attributes}]] = commands
      end
    end

    test "has a handle a keyboard reaches, which controls the panels" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, "button#panel-sheet-handle[type=button][aria-expanded=false]")
      body_id = attribute(view, "#panel-sheet-handle", "aria-controls")
      assert has_element?(view, @sheet <> " #" <> body_id)
    end

    test "sends the server no event for a tab or the handle" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      refute has_element?(view, @sheet <> " [role=tab][phx-click]")
      refute has_element?(view, "#panel-sheet-handle[phx-click]")
    end

    test "holds a place for the trip and nothing else in the Trip tab" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert text(view, "#panel-trip") =~ "Trip planning"
    end

    test "holds the favorite stops' panel in the Favorites tab" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, "#panel-favorites #favorite-stop[phx-hook=FavoriteStop]")
    end

    test "holds the filter's form in the Filter tab" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, "#panel-filter #vehicle-filter")
    end

    test "holds the service alerts in the Alerts tab" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, "#panel-alerts #service-alerts-current")
    end

    test "holds the info panel in the About tab" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, "#panel-about #app-info #app-info-disclaimer")
    end

    test "stands before the map's elements, so the stored filter is offered first" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("main > *")
        |> LazyHTML.attribute("id")

      assert Enum.find_index(ids, &(&1 == "panel-sheet")) <
               Enum.find_index(ids, &(&1 == "vehicle-markers"))
    end

    test "leaves the favorites badge to the favorites' hook" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, "#panel-tab-favorites #favorite-stop-badge[phx-update=ignore]")
    end
  end

  describe "the Filter tab's badge" do
    setup :write_manifest

    test "is absent for a filter that names nothing" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      refute has_element?(view, "#panel-tab-filter-badge")
      assert attribute(view, "#panel-tab-filter", "aria-label") == "Filter"
    end

    test "counts the agencies and the routes the filter names" do
      {:ok, view, _html} = live(build_conn(), "/vehicles?agency=1&route=1_100479,1_100223")

      assert text(view, "#panel-tab-filter-badge") == "3"
      assert attribute(view, "#panel-tab-filter", "aria-label") == "Filter, 3 applied"
    end
  end

  describe "the summary of the filter" do
    setup :write_manifest

    test "says every vehicle is shown under a filter that names nothing" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert summary_parts(view) == ["Showing", "every vehicle"]
    end

    test "names the filter's agencies and routes by the views' names" do
      apply_agencies([{"1", "King County Metro"}])
      apply_routes([{"1_100479", "36"}])

      {:ok, view, _html} = live(build_conn(), "/vehicles?agency=1&route=1_100479")

      assert summary_parts(view) == ["Showing", "King County Metro", "and", "36"]
    end

    test "names a route the route view does not hold by its identifier" do
      {:ok, view, _html} = live(build_conn(), "/vehicles?route=1_999")

      assert summary_parts(view) == ["Showing", "1_999"]
    end

    test "says a refused filter is not valid, with the way back to every vehicle" do
      {:ok, view, _html} = live(build_conn(), "/vehicles?agency[x]=1")

      assert has_element?(view, "#panel-sheet-summary #filter-refused a[href='/vehicles']")
    end
  end

  describe "the Alerts tab's badge" do
    setup :write_manifest

    test "is absent while no alert is current" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      refute has_element?(view, "#panel-tab-alerts-badge")
      assert attribute(view, "#panel-tab-alerts", "aria-label") == "Alerts"
    end

    test "counts the current alerts" do
      apply_current_alerts(2)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert text(view, "#panel-tab-alerts-badge") == "2"
      assert attribute(view, "#panel-tab-alerts", "aria-label") == "Alerts, 2 now"
    end

    test "follows the alerts that arrive after the page mounts" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      apply_current_alerts(1)

      assert text(view, "#panel-tab-alerts-badge") == "1"
    end
  end

  describe "without a basemap" do
    test "offers the About tab alone" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert tab_labels(view) == ["About"]
      assert attribute(view, "#panel-tab-about", "aria-selected") == "true"
      refute has_element?(view, "#panel-about[hidden]")
      assert has_element?(view, "#no-basemap")
    end
  end
end
