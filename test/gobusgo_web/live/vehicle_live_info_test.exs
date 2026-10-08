defmodule GobusgoWeb.VehicleLiveInfoTest do
  # Mounts the vehicle page with Phoenix.LiveViewTest and reads the info
  # button and the panel it opens, with and without a basemap manifest in
  # the test's temporary directory, which the test names as the basemap
  # directory. The agency view fills the panel's credits. Both are global
  # state, hence the non-async case. The browser opens and closes the panel,
  # so these tests observe what the server renders: the button, the command
  # it runs, and the panel's sections.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.OneBusAway.AgencyBatch
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.RouteSchedule
  alias Gobusgo.OneBusAway.Sources
  alias GobusgoWeb.AppInfo
  alias GobusgoWeb.VehicleMarkers

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @button "#app-info-open"
  @panel "#app-info"
  @fetched_at ~U[2026-10-02 03:15:00Z]
  @bounds %{"south" => 47.0, "west" => -123.0, "north" => 48.0, "east" => -122.0}
  @manifest %{
    "snapshot" => "20261004",
    "archives" => [%{"name" => "basemap-20261004-01.pmtiles", "bounds" => @bounds}],
    "agencies" => []
  }

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:gobusgo, :basemap)
    Application.put_env(:gobusgo, :basemap, dir: tmp_dir)
    restart_agency_view()

    on_exit(fn ->
      Application.put_env(:gobusgo, :basemap, configured)
      restart_agency_view()
    end)
  end

  defp restart_agency_view do
    :ok = Supervisor.terminate_child(Gobusgo.Supervisor, AgencyView)
    {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, AgencyView)
  end

  defp write_manifest(tmp_dir) do
    File.write!(Path.join(tmp_dir, "manifest.json"), JSON.encode!(@manifest))
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

  defp attribute(view, selector, name) do
    [value] =
      view
      |> element(selector)
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute(name)

    value
  end

  describe "the info button" do
    test "is shown without a basemap" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, "#no-basemap")
      assert has_element?(view, @button)
      assert has_element?(view, "dialog" <> @panel)
    end

    test "is shown with a basemap", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, @button)
      assert has_element?(view, "dialog" <> @panel)
    end

    test "is shown with a refused filter", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir)
      {:ok, view, _html} = live(build_conn(), "/vehicles?agency[x]=1")

      assert has_element?(view, "#filter-refused")
      assert has_element?(view, @button)
    end

    test "has an accessible name and is a button a keyboard reaches" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert attribute(view, @button, "aria-label") == "About this map"
      assert attribute(view, @button, "type") == "button"
      assert has_element?(view, "button" <> @button)
    end

    test "opens the panel in the browser, with no event for the server" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      commands = view |> attribute(@button, "phx-click") |> JSON.decode!()

      assert [["dispatch", %{"event" => "gobusgo:show-modal", "to" => @panel}]] = commands
    end
  end

  describe "the info panel" do
    test "closes through a form of the dialog method, with no event for the server" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, @panel <> " form[method=dialog] button")
      refute has_element?(view, @panel <> " [phx-click]")
      refute has_element?(view, @panel <> " [phx-submit]")
    end

    test "keeps the open state the browser gives it when the page is patched" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      commands = view |> attribute(@panel, "phx-mounted") |> JSON.decode!()

      assert [["ignore_attrs", %{"attrs" => ["open"]}]] = commands
    end

    test "is labeled by its heading" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      heading_id = attribute(view, @panel, "aria-labelledby")

      assert has_element?(view, @panel <> " #" <> heading_id)
    end

    test "says what the app is" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert panel_text(view) =~ AppInfo.about()
    end

    test "carries the disclaimer in a section of its own" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view |> element(@panel <> " #app-info-disclaimer") |> render() =~
               AppInfo.disclaimer()
    end

    for %{status: status, label: label, description: description, color: color} <-
          VehicleMarkers.statuses() do
      test "explains the #{status} status with its color" do
        {:ok, view, _html} = live(build_conn(), "/vehicles")
        entry = @panel <> " #app-info-status-#{unquote(status)}"

        assert view |> element(entry) |> render() =~ unquote(label)
        assert view |> element(entry) |> render() =~ unquote(description)
        assert view |> element(entry) |> render() =~ unquote(color)
      end
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

      paragraphs =
        AppInfo.data_use(%{
          vehicle_interval_ms: Sources.vehicle_interval_ms_min(),
          route_period_minutes: RouteSchedule.period_minutes()
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
        |> LazyHTML.query("[id^=app-info-recorded-]")
        |> Enum.count()

      assert entries == length(Gobusgo.Usage.Records.fields())
    end

    test "says what the usage record never holds" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert panel_text(view) =~ AppInfo.recorded_never()
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
  end
end
