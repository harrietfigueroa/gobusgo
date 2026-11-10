defmodule GobusgoWeb.VehicleLiveConnectionTest do
  # Mounts the map pages with Phoenix.LiveViewTest and reads what the server
  # renders for the page's connection state: the element of the hook that
  # reports the join, the offline signal and its live region, the summary
  # line's offline prefix, and the notes that say in place what needs a
  # connection. The browser decides the state and the stylesheet shows and
  # hides by it, so these tests observe the markup alone. The basemap
  # directory is application configuration, global state, hence the
  # non-async case.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @moduletag :tmp_dir

  @endpoint GobusgoWeb.Endpoint
  @bounds %{"south" => 47.0, "west" => -123.0, "north" => 48.0, "east" => -122.0}
  @manifest %{
    "snapshot" => "20261004",
    "archives" => [%{"name" => "basemap-20261004-01.pmtiles", "bounds" => @bounds}],
    "agencies" => []
  }
  @signal "#connection-signal"

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:gobusgo, :basemap)
    Application.put_env(:gobusgo, :basemap, dir: tmp_dir)
    on_exit(fn -> Application.put_env(:gobusgo, :basemap, configured) end)
  end

  defp write_manifest(tmp_dir) do
    File.write!(Path.join(tmp_dir, "manifest.json"), JSON.encode!(@manifest))
  end

  defp text(view, selector) do
    view |> element(selector) |> render() |> LazyHTML.from_fragment() |> LazyHTML.text()
  end

  describe "the connection state's hook" do
    test "stands in the vehicle page with a basemap", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, ~s(#connection-state[phx-hook="ConnectionState"][hidden]))
    end

    test "stands in the vehicle page without a basemap" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, ~s(#connection-state[phx-hook="ConnectionState"]))
    end

    for path <- ["/", "/agencies"] do
      test "stands in the page at #{path}" do
        {:ok, view, _html} = live(build_conn(), unquote(path))

        assert has_element?(view, ~s(#connection-state[phx-hook="ConnectionState"]))
      end
    end
  end

  describe "the offline signal" do
    test "is a button over the map that its hook writes and the server leaves alone", %{
      tmp_dir: tmp_dir
    } do
      write_manifest(tmp_dir)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(
               view,
               ~s(button#{@signal}[type="button"][phx-hook="ConnectionSignal"][phx-update="ignore"])
             )
    end

    test "opens the Settings tab's offline section", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, @signal <> ~s([data-section-id="app-info-offline"]))
      assert has_element?(view, "#panel-settings #app-info-offline")
    end

    test "draws an icon hidden from assistive technology beside its text", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, @signal <> " svg[aria-hidden=true]")
      assert text(view, @signal <> " [data-signal-headline]") == "Offline"
    end

    test "holds a caption that starts hidden", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, @signal <> " [data-signal-caption][hidden]")
    end

    test "names a polite live region that starts empty", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, @signal <> ~s([data-announcer-id="connection-announcement"]))

      assert has_element?(
               view,
               ~s(#connection-announcement[role="status"][aria-live="polite"][phx-update="ignore"])
             )

      assert text(view, "#connection-announcement") == ""
    end

    test "is not drawn without a basemap" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      refute has_element?(view, @signal)
    end
  end

  describe "the summary line" do
    test "opens with an offline prefix the stylesheet shows offline", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert text(view, "#panel-sheet-summary .offline-prefix") == "Offline · "
    end

    test "opens with the prefix under a refused filter", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir)
      {:ok, view, _html} = live(build_conn(), "/vehicles?agency[x]=1")

      assert has_element?(view, "#filter-refused .offline-prefix")
    end
  end

  describe "what needs a connection" do
    test "the Alerts tab says service alerts need one, in place of its alerts", %{
      tmp_dir: tmp_dir
    } do
      write_manifest(tmp_dir)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert text(view, "#service-alerts .offline-note") ==
               "Service alerts need a connection. They come back when you're online."

      assert has_element?(view, "#service-alerts .needs-connection #service-alerts-current")
    end

    test "the filter bar says suggestions need one, in place of its suggestions", %{
      tmp_dir: tmp_dir
    } do
      write_manifest(tmp_dir)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert text(view, "#vehicle-filter-bar .offline-note") ==
               "Suggestions need a connection. They come back when you're online."

      assert has_element?(view, "#vehicle-filter-suggestions.needs-connection")
    end

    test "the shared vehicle control says scooters and bikes need one", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert text(view, "#shared-vehicles .offline-note") ==
               "Scooters and bikes need a connection. They come back when you're online."
    end
  end
end
