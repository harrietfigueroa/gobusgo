defmodule GobusgoWeb.VehicleLiveInfoTest do
  # Mounts the vehicle page with Phoenix.LiveViewTest and reads the info
  # panel of the Settings tab, with and without a basemap manifest in the
  # test's temporary directory, which the test names as the basemap
  # directory. The agency view fills the panel's credits. Both are global
  # state, hence the non-async case. The browser opens the tab, so these
  # tests observe what the server renders: the tab and the panel's sections.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.OneBusAway.AgencyBatch
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.RouteSchedule
  alias Gobusgo.OneBusAway.Sources
  alias GobusgoWeb.AppInfo
  alias GobusgoWeb.AppInfoPanel
  alias GobusgoWeb.VehicleMarkers

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @tab "#panel-tab-settings"
  @panel "#app-info"
  @fetched_at ~U[2026-10-02 03:15:00Z]
  @bounds %{"south" => 47.0, "west" => -123.0, "north" => 48.0, "east" => -122.0}
  @manifest %{
    "snapshot" => "20261004",
    "archives" => [%{"name" => "basemap-20261004-01.pmtiles", "bounds" => @bounds}],
    "agencies" => []
  }
  @offline_bytes 34_355_445
  @offline_manifest %{
    "snapshot" => "20261004",
    "archives" => [
      %{
        "name" => "basemap-20261004-01.pmtiles",
        "bounds" => @bounds,
        "offline" => %{
          "name" => "basemap-20261004-01-z13.pmtiles",
          "bytes" => @offline_bytes,
          "zoomMax" => 13
        }
      }
    ],
    "agencies" => []
  }

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:gobusgo, :basemap)
    configured_revision = Application.get_env(:gobusgo, :revision)
    Application.put_env(:gobusgo, :basemap, dir: tmp_dir)
    restart_agency_view()

    on_exit(fn ->
      Application.put_env(:gobusgo, :basemap, configured)
      Application.put_env(:gobusgo, :revision, configured_revision)
      restart_agency_view()
    end)
  end

  defp restart_agency_view do
    :ok = Supervisor.terminate_child(Gobusgo.Supervisor, AgencyView)
    {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, AgencyView)
  end

  defp write_manifest(tmp_dir, manifest \\ @manifest) do
    File.write!(Path.join(tmp_dir, "manifest.json"), JSON.encode!(manifest))
  end

  # Publishes a fetch of agencies, each `{id, name}`.
  defp apply_agencies(agencies) do
    %{agencies: records, manifest: manifest} =
      AgencyBatch.Records.build(%{
        destination: "raw/oba/agencies-with-coverage/dt=2026-10-02/file.json",
        fetched_at: @fetched_at,
        data_sha256: String.duplicate("ab", 32),
        request_id: "0199c4a2-7e1b-7a3f-9d20-000000000000",
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

  defp panel_text(view) do
    view |> element(@panel) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
  end

  defp text(view, selector) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
  end

  defp attribute(view, selector, name) do
    [value] =
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute(name)

    value
  end

  # The ids of the elements `selector` matches, in document order.
  defp ids(view, selector) do
    view
    |> render()
    |> LazyHTML.from_document()
    |> LazyHTML.query(selector)
    |> Enum.flat_map(&LazyHTML.attribute(&1, "id"))
  end

  describe "the Settings tab" do
    test "is named Settings" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view |> element(@tab <> " [data-tab-label]") |> render() =~ ">Settings<"
    end

    test "draws the settings icon" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, @tab <> " svg.panel-sheet-icon[aria-hidden=true]")
    end

    test "holds the info panel without a basemap" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, "#no-basemap")
      assert attribute(view, @tab, "aria-controls") == "panel-settings"
      assert has_element?(view, "#panel-settings " <> @panel)
    end

    test "holds the info panel with a basemap", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, "#panel-settings " <> @panel)
    end

    test "is offered with a refused filter", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir)
      {:ok, view, _html} = live(build_conn(), "/vehicles?agency[x]=1")

      assert has_element?(view, "#filter-refused")
      assert has_element?(view, @tab)
    end
  end

  describe "the info panel's order" do
    test "puts the settings group before the About information" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert ids(view, @panel <> " > section") == ["app-info-settings", "app-info-about"]
    end

    test "holds installing the app, the theme, offline, offline schedules, and the direction in the settings group, in that order" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert ids(view, "#app-info-settings > section") == [
               "app-info-install",
               "app-info-theme",
               "app-info-offline",
               "app-info-offline-schedules",
               "app-info-show-direction"
             ]
    end

    test "heads the settings group with a Settings heading" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view |> element("#app-info-settings > h2") |> render() =~ ">Settings<"
    end

    test "heads the About information with an About heading" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view |> element("#app-info-about > h2") |> render() =~ ">About<"
    end

    test "holds the About sections under the About heading, in their order" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert ids(view, "#app-info-about > section[id]") == [
               "app-info-disclaimer",
               "app-info-legend",
               "app-info-data-use",
               "app-info-shared-vehicles",
               "app-info-location",
               "app-info-favorite-stop",
               "app-info-recorded",
               "app-info-credits",
               "app-info-licenses"
             ]
    end

    test "holds what the app is under the About heading" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert text(view, "#app-info-about > #app-info-what") ==
               "A live transit map of Puget Sound. " <>
                 "Where each vehicle is, the routes it runs on, and the stops it serves"
    end
  end

  describe "the info panel's headlines and captions" do
    for {section, headline, caption} <- [
          {"app-info-install", "Install Gobusgo", nil},
          {"app-info-theme", "Theme", "Match system follows your device's light or dark setting"},
          {"app-info-offline", "Offline",
           "The map, saved schedules, favorites, and trip planning keep working"},
          {"app-info-disclaimer", "An independent project",
           "Check with your agency before you rely on a position or a time."},
          {"app-info-shared-vehicles", "Scooters and bikes every 60 seconds",
           "Only while a page shows them"},
          {"app-info-location", "Your location stays in your browser",
           "Gobusgo's server never receives it"},
          {"app-info-favorite-stop", "Favorites stay in your browser",
           "The server learns a stop only to fetch its arrivals"},
          {"app-info-recorded", "One anonymous record per page visit",
           "No address, cookie, or identifier of you, kept 3 days"},
          {"app-info-credits", "Data from the region's transit agencies",
           "Served by OneBusAway · map data © OpenStreetMap contributors"},
          {"app-info-licenses", "Open source under the MIT License",
           "Copyright (c) 2026 Harriet Waters"}
        ] do
      test "heads #{section} with its headline and caption" do
        {:ok, view, _html} = live(build_conn(), "/vehicles")
        selector = "#" <> unquote(section)

        assert text(view, selector <> " > h3.message-headline") == unquote(headline)

        if unquote(caption) do
          assert text(view, selector <> " > p.message-caption") == unquote(caption)
        end
      end
    end

    for {input, headline, caption} <- [
          {"offline-schedules-enabled", "Save schedules offline",
           "Plan trips and see scheduled times without signal"},
          {"show-direction-enabled", "Show my direction",
           "Your location dot points the way you face or travel"}
        ] do
      test "names the #{input} checkbox by its headline and describes it by its caption" do
        {:ok, view, _html} = live(build_conn(), "/vehicles")
        input = unquote(input)

        assert text(view, ~s(label[for="#{input}"])) == unquote(headline)
        assert attribute(view, "#" <> input, "aria-describedby") == input <> "-caption"
        assert text(view, "#" <> input <> "-caption") == unquote(caption)
      end
    end

    test "states the OneBusAway cadences as facts, each a headline and a caption" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      facts =
        view
        |> element("#app-info-data-use")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("p.app-info-fact")
        |> Enum.map(&LazyHTML.text/1)

      assert facts == [
               "Live vehicles every 10 seconds. From OneBusAway, while a map is open",
               "Arrivals every 30 seconds to 5 minutes. " <>
                 "For the stops you open and your favorites, faster when fewer are open",
               "Routes and stops once a day. Each route at a minute of its own",
               "Service alerts with each read. For the trips running now and the stops that are open"
             ]
    end

    for {disclosure, summary} <- [
          {"app-info-theme-more", "How the theme is kept"},
          {"app-info-offline-more", "What works and what needs a connection"},
          {"app-info-offline-schedules-more", "How schedules are saved"},
          {"app-info-show-direction-more", "How your direction is found"},
          {"app-info-disclaimer-more", "Full disclaimer"},
          {"app-info-data-use-more", "How OneBusAway data is used"},
          {"app-info-shared-vehicles-more", "How scooter and bike data is used"},
          {"app-info-location-more", "How your location is used"},
          {"app-info-favorite-stop-more", "How favorites are kept"},
          {"app-info-recorded-more", "What a record holds, and the cookie"},
          {"app-info-credits-more", "Credits and data terms"},
          {"app-info-licenses-more", "Licenses"}
        ] do
      test "holds the full sentences of #{disclosure} behind a closed disclosure" do
        {:ok, view, _html} = live(build_conn(), "/vehicles")
        selector = "#" <> unquote(disclosure)

        assert has_element?(view, "details" <> selector <> ":not([open])")
        assert text(view, selector <> " > summary") == unquote(summary)
      end
    end

    test "holds the transit data terms and the credits behind their disclosure" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      %{url: url} = AppInfo.terms()

      assert has_element?(view, ~s(#app-info-credits-more a[href="#{url}"]))
      assert text(view, "#app-info-credits-more") =~ "OpenStreetMap contributors"
    end

    test "credits each address source and links its terms behind the credits' disclosure" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      for %{terms: %{url: url}, operator: operator} <- AppInfo.address_sources() do
        assert has_element?(view, ~s(#app-info-credits-more a[href="#{url}"]))
        assert text(view, "#app-info-address-source") =~ operator
      end
    end

    test "credits OpenStreetMap for the intersections and links the license they are offered under" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      %{license: %{url: url}, credit: credit} = AppInfo.intersection_source()

      assert has_element?(view, ~s(#app-info-credits-more a[href="#{url}"]))
      assert text(view, "#app-info-intersection-source") =~ credit
      assert text(view, "#app-info-intersection-source") =~ "Open Database License"
      assert text(view, "#app-info-intersection-source") =~ "/intersections/"
    end

    test "holds every field of the usage record, what it never holds, and the cookie behind their disclosure" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      disclosure = text(view, "#app-info-recorded-more")

      for %{text: field_text} <- AppInfo.recorded() do
        assert disclosure =~ field_text
      end

      assert disclosure =~ AppInfo.recorded_never()
      assert has_element?(view, "#app-info-recorded-more #app-info-session-cookie")
    end

    test "holds every license behind its disclosure" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      disclosure = text(view, "#app-info-licenses-more")

      for %{name: name, license: license} <- AppInfo.components() do
        assert disclosure =~ name
        assert disclosure =~ license
      end
    end
  end

  describe "the info panel's shared scooters and bikes" do
    test "credits Lime with a link to its Public GBFS Terms" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert attribute(view, "#app-info-shared-vehicles-lime_seattle a", "href") ==
               "https://www.li.me/legal/public-gbfs-terms"
    end

    # The texts are built from the facts the source, the recorder, and the
    # retention run on, so the panel says what the configuration does.
    test "states the facts the source and the retention run on" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      section = view |> element("#app-info-shared-vehicles") |> render()

      for paragraph <- AppInfo.shared_vehicles(AppInfoPanel.shared_vehicle_facts()) do
        assert section =~ Phoenix.HTML.html_escape(paragraph) |> Phoenix.HTML.safe_to_string()
      end
    end

    test "reads the configured interval, the vehicle type cadence, and the kept age" do
      facts = AppInfoPanel.shared_vehicle_facts()
      {:ok, %{interval_ms: interval_ms}} = Gobusgo.Config.shared_vehicles()

      assert {facts.interval_ms, facts.types_period_minutes, facts.stored_age_ms_max} ==
               {interval_ms, RouteSchedule.period_minutes(),
                Gobusgo.Gbfs.VehicleStatusRetention.stored_age_ms_max()}
    end
  end

  describe "the info panel" do
    test "sends the server no event" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      refute has_element?(view, @panel <> " [phx-click]")
      refute has_element?(view, @panel <> " [phx-submit]")
    end

    test "says how a vehicle is drawn zoomed in and zoomed out" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      text = view |> panel_text() |> String.replace(~r/\s+/, " ")

      assert text =~
               "Zoomed in, a vehicle is a bus with its route's number on its shoulder and a " <>
                 "chevron the way it is heading; zoomed out, a dot."
    end

    test "carries the disclaimer in a section of its own" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view |> element(@panel <> " #app-info-disclaimer") |> render() =~
               AppInfo.disclaimer()
    end

    for %{status: status, label: label} <- VehicleMarkers.statuses() do
      test "labels the #{status} status beside its glyph" do
        {:ok, view, _html} = live(build_conn(), "/vehicles")
        entry = @panel <> " #app-info-status-#{unquote(status)}"
        %{fill: fill} = AppInfoPanel.glyph_swatch(unquote(status))

        assert view |> element(entry) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() =~
                 unquote(label)

        assert has_element?(view, entry <> " svg.status-glyph circle[fill='#{fill}']")
      end
    end

    for %{status: status, badge: badge} <- VehicleMarkers.statuses(), badge != nil do
      test "draws the #{status} status's #{badge} badge beside its swatch" do
        {:ok, view, _html} = live(build_conn(), "/vehicles")
        badge = @panel <> " #app-info-status-#{unquote(status)} [data-badge=#{unquote(badge)}]"

        assert has_element?(view, badge)
      end
    end

    test "draws no badge beside the reported status's swatch" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      refute has_element?(view, @panel <> " #app-info-status-reported [data-badge]")
    end

    for {status, glyph} <- [
          {:reported, %{fill: "#b91c1c", stroke: "#ffffff", dasharray: "none", ink: "#ffffff"}},
          {:stale, %{fill: "#eec6c6", stroke: "#334155", dasharray: "none", ink: "#334155"}},
          {:unknown, %{fill: "#eec6c6", stroke: "#334155", dasharray: "1 2", ink: "#334155"}},
          {:scheduled, %{fill: "#ffffff", stroke: "#475569", dasharray: "3 2", ink: "#475569"}}
        ] do
      test "draws the #{status} glyph as the map draws it" do
        assert AppInfoPanel.glyph_swatch(unquote(status)) == unquote(Macro.escape(glyph))
      end
    end

    for {id, label} <- [{"ring", "Last report"}, {"line", "Path since the last report"}] do
      test "labels the tie's #{id} beside its swatch" do
        {:ok, view, _html} = live(build_conn(), "/vehicles")
        entry = @panel <> " #app-info-tie-#{unquote(id)}"

        assert view |> element(entry) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text() =~
                 unquote(label)

        assert has_element?(view, entry <> " svg.report-tie")
      end
    end

    test "says a live vehicle's marker is an estimate tied to its last report" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      text = view |> panel_text() |> String.replace(~r/\s+/, " ")

      assert text =~
               "A live vehicle's marker is an estimate: between reports it moves along its " <>
                 "route at the schedule's pace. Zoomed in, and for the vehicle you select, a " <>
                 "ring marks its last report and a dashed line joins the ring to the marker " <>
                 "along the route."
    end

    test "has one legend entry per status" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      entries =
        view
        |> element(@panel)
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("[id^=app-info-status-]")
        |> Enum.count()

      assert entries == length(VehicleMarkers.statuses())
    end

    test "says how OneBusAway data is used, with the configured cadences" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      text = panel_text(view)

      {:proportional, %{interval_ms_min: age_ms_min, interval_ms_max: age_ms_max}} =
        Sources.arrival_refresh_policy()

      paragraphs =
        AppInfo.data_use(%{
          vehicle_interval_ms: Sources.vehicle_interval_ms_min(),
          route_period_minutes: RouteSchedule.period_minutes(),
          arrival_refresh_age_ms_min: age_ms_min,
          arrival_refresh_age_ms_max: age_ms_max
        })

      for paragraph <- paragraphs do
        assert text =~ paragraph
      end
    end

    for %{field: field, text: text} <- AppInfo.recorded() do
      test "says the usage record holds #{field}" do
        {:ok, view, _html} = live(build_conn(), "/vehicles")

        assert view |> element(@panel <> " #app-info-recorded-#{unquote(field)}") |> render() =~
                 Phoenix.HTML.html_escape(unquote(text)) |> Phoenix.HTML.safe_to_string()
      end
    end

    test "has one entry per field of the usage record" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      entries =
        view
        |> element(@panel)
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("li[id^=app-info-recorded-]")
        |> Enum.count()

      assert entries == length(Gobusgo.Usage.Records.fields())
    end

    test "says how long a usage record is kept, by the retention policy" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view |> element(@panel <> " #app-info-recorded-retention") |> render() =~
               AppInfo.recorded_retention(Gobusgo.RetentionPolicy.usage_day_count())
    end

    test "says what the usage record never holds" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert panel_text(view) =~ AppInfo.recorded_never()
    end

    test "says how the rider's location is used, in a section of its own" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      text =
        view
        |> element(@panel <> " #app-info-location")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert text =~ AppInfo.location()
    end

    test "says how favorite stops are kept, in a section of its own" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      text =
        view
        |> element(@panel <> " #app-info-favorite-stop")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert text =~ AppInfo.favorite_stop()
    end

    test "heads the offline section with an Offline heading" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view |> element(@panel <> " #app-info-offline > h3") |> render() =~ ">Offline<"
    end

    test "lists what works offline and what needs a connection in the offline section" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      %{works: works, needs_connection: needs_connection} = AppInfo.offline()

      items = fn list ->
        view
        |> render()
        |> LazyHTML.from_document()
        |> LazyHTML.query("#app-info-offline #{list} li")
        |> Enum.map(&LazyHTML.text/1)
      end

      assert items.("#app-info-offline-works") == works
      assert items.("#app-info-offline-needs-connection") == needs_connection
    end

    test "lets the offline signal move focus to the offline section" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, @panel <> ~s( #app-info-offline[tabindex="-1"]))
    end

    test "says how schedules are saved for offline use, in a section of its own" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      text =
        view
        |> element(@panel <> " #app-info-offline-schedules")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert text =~ AppInfo.offline_schedules()
    end

    test "offers the offline schedules setting, checked until the browser reads the rider's" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, @panel <> " #offline-schedules-enabled[type=checkbox][checked]")
    end

    test "hands the offline schedules section to its hook, which the server leaves alone" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(
               view,
               @panel <>
                 ~s( #app-info-offline-schedules[phx-hook="OfflineSchedules"][phx-update="ignore"])
             )
    end

    test "offers no offline map setting for a basemap without an offline extract", %{
      tmp_dir: tmp_dir
    } do
      write_manifest(tmp_dir)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      refute has_element?(view, @panel <> " #app-info-offline-basemap")
    end

    test "puts the offline map setting after the offline schedules", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, @offline_manifest)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert ids(view, "#app-info-settings > section") == [
               "app-info-install",
               "app-info-theme",
               "app-info-offline",
               "app-info-offline-schedules",
               "app-info-offline-basemap",
               "app-info-show-direction"
             ]
    end

    test "says how the map is saved for offline use, with its size", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, @offline_manifest)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      text =
        view
        |> element(@panel <> " #app-info-offline-basemap")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert text =~ AppInfo.offline_basemap(%{bytes: @offline_bytes})
      assert text(view, ~s(label[for="offline-basemap-enabled"])) == "Save the map offline"

      assert text(view, "#offline-basemap-enabled-caption") ==
               "Keeps streets and places when you lose signal · 34 MB"
    end

    test "offers the offline map setting unchecked, the default", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, @offline_manifest)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, @panel <> " #offline-basemap-enabled[type=checkbox]")
      refute has_element?(view, @panel <> " #offline-basemap-enabled[checked]")
    end

    test "hands the offline map setting the extract's address", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, @offline_manifest)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      selector =
        @panel <> ~s( #app-info-offline-basemap[phx-hook="OfflineBasemap"][phx-update="ignore"])

      assert attribute(view, selector, "data-archive-url") ==
               "/basemap/basemap-20261004-01-z13.pmtiles"
    end

    test "says what Show my direction draws, in a section of its own" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      text =
        view
        |> element(@panel <> " #app-info-show-direction")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert text =~ AppInfo.show_direction()
    end

    test "offers the Show my direction setting, checked until the browser reads the rider's" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view
             |> element(@panel <> " #app-info-show-direction label")
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.text() =~ "Show my direction"

      assert has_element?(view, @panel <> " #show-direction-enabled[type=checkbox][checked]")
    end

    test "hands the Show my direction section to its hook, which the server leaves alone" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(
               view,
               @panel <>
                 ~s( #app-info-show-direction[phx-hook="ShowDirection"][phx-update="ignore"])
             )
    end

    test "hands the install section to its hook, hidden until the browser offers an install" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(
               view,
               @panel <>
                 ~s( #app-info-install[hidden][phx-hook="InstallApp"][phx-update="ignore"])
             )
    end

    for %{kind: kind, caption: caption} <- AppInfo.install_offers() do
      test "holds the #{kind} install offer, hidden until the browser picks it" do
        {:ok, view, _html} = live(build_conn(), "/vehicles")

        offer =
          view
          |> element(
            @panel <> ~s( #app-info-install [data-install-kind="#{unquote(kind)}"][hidden])
          )
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.text()

        assert offer =~ unquote(caption)
      end
    end

    test "offers an install button inside the browser's install offer" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view
             |> element(@panel <> ~s( #app-info-install [data-install-kind="prompt"] button))
             |> render() =~ "Install app"
    end

    test "says how the theme is kept, in a section of its own" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      text =
        view
        |> element(@panel <> " #app-info-theme")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.text()

      assert text =~ AppInfo.theme()
    end

    test "offers the three theme settings, Match system checked until the browser reads the rider's" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      for value <- ["light", "dark"] do
        assert has_element?(view, @panel <> ~s( #theme-setting-#{value}[type=radio][name=theme]))
        refute has_element?(view, @panel <> ~s( #theme-setting-#{value}[checked]))
      end

      assert has_element?(
               view,
               @panel <> " #theme-setting-system[type=radio][name=theme][checked]"
             )
    end

    test "names the theme settings Light, Dark, and Match system" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      labels =
        view
        |> element(@panel <> " #app-info-theme fieldset")
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("label")
        |> Enum.map(&String.trim(LazyHTML.text(&1)))

      assert labels == ["Light", "Dark", "Match system"]
    end

    test "hands the theme section to its hook, which the server leaves alone" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(
               view,
               @panel <> ~s( #app-info-theme[phx-hook="ColorTheme"][phx-update="ignore"])
             )
    end

    test "links the terms the data is provided under" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      %{name: name, url: url} = AppInfo.terms()

      assert view |> element(@panel <> ~s( a[href="#{url}"])) |> render() =~ name
    end

    test "credits the agencies of the agency view" do
      apply_agencies([{"40", "Sound Transit"}, {"1", "Metro Transit"}])
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      text = panel_text(view)

      assert text =~ "Sound Transit"
      assert text =~ "Metro Transit"
    end

    test "credits agencies that arrive after the page is open" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      refute panel_text(view) =~ "Metro Transit"

      apply_agencies([{"1", "Metro Transit"}])

      assert panel_text(view) =~ "Metro Transit"
    end

    test "credits OneBusAway and OpenStreetMap" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      text = panel_text(view)

      assert text =~ "OneBusAway"
      assert text =~ "OpenStreetMap"
    end

    test "states the app's license and copyright" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      %{name: name, copyright: copyright} = AppInfo.app_license()
      text = panel_text(view)

      assert text =~ name
      assert text =~ copyright
    end

    test "names every component with its license" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      text = panel_text(view)

      for %{name: name, license: license} <- AppInfo.components() do
        assert text =~ name
        assert text =~ license
      end
    end

    test "names the commit the application was built from" do
      revision = "43402796c905c22db533043dee878950c74d5791"
      Application.put_env(:gobusgo, :revision, revision: revision)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view |> element(@panel <> " #app-info-revision") |> render() =~ revision
    end

    test "names no commit for an application built without one" do
      Application.put_env(:gobusgo, :revision, revision: nil)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      refute has_element?(view, @panel <> " #app-info-revision")
    end
  end
end
