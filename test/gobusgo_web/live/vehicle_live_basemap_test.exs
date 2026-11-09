defmodule GobusgoWeb.VehicleLiveBasemapTest do
  # Mounts the vehicle page with Phoenix.LiveViewTest over a basemap
  # directory the test writes: a manifest of two archives and three agencies
  # in the test's temporary directory, which the test names as the basemap
  # directory, hence the non-async case. The map itself is drawn by the
  # browser, so these tests observe what the page hands it: the element, its
  # sources and bounds, and the event that moves the view.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias GobusgoWeb.MapLibrary

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @west_archive "basemap-20261004-01.pmtiles"
  @east_archive "basemap-20261004-02.pmtiles"
  @west_bounds %{"south" => 9.0, "west" => 9.0, "north" => 12.0, "east" => 12.5}
  @east_bounds %{"south" => 9.0, "west" => 29.0, "north" => 11.0, "east" => 31.0}
  @near_bounds %{"south" => 10.0, "west" => 10.5, "north" => 12.0, "east" => 12.5}
  @far_bounds %{"south" => 9.0, "west" => 9.0, "north" => 11.0, "east" => 11.0}
  @manifest %{
    "snapshot" => "20261004",
    "archives" => [
      %{"name" => @west_archive, "bounds" => @west_bounds},
      %{"name" => @east_archive, "bounds" => @east_bounds}
    ],
    "agencies" => [
      %{"agencyId" => "far", "archive" => @west_archive, "bounds" => @far_bounds},
      %{"agencyId" => "near", "archive" => @west_archive, "bounds" => @near_bounds},
      %{"agencyId" => "east", "archive" => @east_archive, "bounds" => @east_bounds}
    ]
  }
  @west_map "#basemap-basemap-20261004-01"
  @east_map "#basemap-basemap-20261004-02"
  @follow "#follow-location"

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:gobusgo, :basemap)
    Application.put_env(:gobusgo, :basemap, dir: tmp_dir)
    on_exit(fn -> Application.put_env(:gobusgo, :basemap, configured) end)
    :ok
  end

  defp write_manifest(tmp_dir, content \\ JSON.encode!(@manifest)) do
    File.write!(Path.join(tmp_dir, "manifest.json"), content)
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

  defp bounds(view, selector), do: view |> attribute(selector, "data-bounds") |> JSON.decode!()

  describe "GET /vehicles without a basemap" do
    test "says that no basemap is available and draws no map" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view |> element("#no-basemap") |> render() =~ "No basemap yet."
      refute has_element?(view, "[phx-hook=Basemap]")
    end

    test "draws no map for a manifest that cannot be used, and logs it once", %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir, "not json")

      log =
        capture_log(fn ->
          {:ok, view, _html} = live(build_conn(), "/vehicles")
          assert has_element?(view, "#no-basemap")
        end)

      assert log =~ "Basemap manifest not usable"
    end

    test "has no element for the location button" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      refute has_element?(view, @follow)
    end
  end

  describe "GET /vehicles with a basemap" do
    setup %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir)
    end

    test "hands the map the first archive, the fonts, the sprites, and the attribution" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert attribute(view, @west_map, "phx-hook") == "Basemap"
      assert attribute(view, @west_map, "phx-update") == "ignore"
      assert attribute(view, @west_map, "data-archive-url") == "/basemap/#{@west_archive}"
      assert attribute(view, @west_map, "data-fonts-url") == "/vendor/basemaps-assets/fonts"

      assert attribute(view, @west_map, "data-sprites-url") ==
               "/vendor/basemaps-assets/sprites/v4"

      assert attribute(view, @west_map, "data-attribution") =~ "OpenStreetMap"
      refute has_element?(view, "#no-basemap")
    end

    test "names no offline extract for an archive without one" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      refute has_element?(view, @west_map <> "[data-offline-archive-url]")
    end

    test "hands the map the archive's offline extract", %{tmp_dir: tmp_dir} do
      offline = %{"name" => "basemap-20261004-01-z13.pmtiles", "bytes" => 34, "zoomMax" => 13}
      [west, east] = @manifest["archives"]
      archives = [Map.put(west, "offline", offline), east]
      write_manifest(tmp_dir, JSON.encode!(%{@manifest | "archives" => archives}))
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert attribute(view, @west_map, "data-offline-archive-url") ==
               "/basemap/basemap-20261004-01-z13.pmtiles"
    end

    test "fits the whole archive when no agency is chosen" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert bounds(view, @west_map) == @west_bounds
    end

    test "shows the offline signal, the panel sheet, the map, and the hooks' elements, and nothing else" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      ids =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("main > *")
        |> LazyHTML.attribute("id")

      assert ids == [
               "connection-state",
               "connection-signal",
               "connection-announcement",
               "panel-sheet",
               "basemap-basemap-20261004-01",
               "route-stop-tiles",
               "shared-vehicles-layer",
               "stop-markers",
               "vehicle-markers",
               "route-lines",
               "follow-location"
             ]
    end

    test "fits the coverage of the agency the address names" do
      {:ok, view, _html} = live(build_conn(), "/vehicles?agency=near")

      assert bounds(view, @west_map) == @near_bounds
    end

    test "draws from the archive that holds the agency the address names" do
      {:ok, view, _html} = live(build_conn(), "/vehicles?agency=east")

      assert attribute(view, @east_map, "data-archive-url") == "/basemap/#{@east_archive}"
      assert bounds(view, @east_map) == @east_bounds
    end

    test "fits the whole archive for an agency the basemap does not hold" do
      {:ok, view, _html} = live(build_conn(), "/vehicles?agency=6289")

      assert bounds(view, @west_map) == @west_bounds
    end

    test "mounts the location button's hook on a notice that a patch leaves alone" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert attribute(view, @follow, "phx-hook") == "FollowLocation"
      assert attribute(view, @follow, "phx-update") == "ignore"
    end

    test "makes the notice a polite live region that stays in the page" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert attribute(view, @follow, "role") == "status"
      assert attribute(view, @follow, "aria-live") == "polite"
      refute has_element?(view, @follow <> "[hidden]")
    end

    test "starts the notice not shown" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert attribute(view, @follow, "data-shown") == "false"
    end

    test "starts the notice empty" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view
             |> element(@follow)
             |> render()
             |> LazyHTML.from_fragment()
             |> LazyHTML.text()
             |> String.trim() == ""
    end

    test "hands the location button the bounds of the whole archive" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert bounds(view, @follow) == @west_bounds
    end

    test "hands the location button the whole archive's bounds under a filter by one agency" do
      {:ok, view, _html} = live(build_conn(), "/vehicles?agency=near")

      assert bounds(view, @follow) == @west_bounds
    end

    test "hands the location button the bounds of the archive that holds the agency the address names" do
      {:ok, view, _html} = live(build_conn(), "/vehicles?agency=east")

      assert bounds(view, @follow) == @east_bounds
    end

    test "hands the map the address of the library at the version in use" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert attribute(view, @west_map, "data-library-url") ==
               MapLibrary.url(MapLibrary.version())
    end

    test "names nothing about vehicles on the map element" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      names =
        view
        |> element(@west_map)
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.attributes()
        |> List.flatten()
        |> Enum.map(&elem(&1, 0))

      assert Enum.sort(names) ==
               ~w(class data-archive-url data-attribution data-bounds data-fonts-url data-library-url data-sprites-url data-style-validated id phx-hook phx-update)
    end

    test "has the map check its styles outside production" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert attribute(view, @west_map, "data-style-validated") == ""
    end
  end

  describe "a new address on an open page" do
    setup %{tmp_dir: tmp_dir} do
      write_manifest(tmp_dir)
    end

    test "moves the map to an agency of the archive it shows" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      render_patch(view, "/vehicles?agency=near")

      assert_push_event(view, "basemap:fit", %{
        bounds: %{south: 10.0, west: 10.5, north: 12.0, east: 12.5}
      })
    end

    test "moves the map back to the whole archive" do
      {:ok, view, _html} = live(build_conn(), "/vehicles?agency=near")

      render_patch(view, "/vehicles")

      assert_push_event(view, "basemap:fit", %{
        bounds: %{south: 9.0, west: 9.0, north: 12.0, east: 12.5}
      })
    end

    test "draws a new map for an agency of another archive" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      render_patch(view, "/vehicles?agency=east")

      assert has_element?(view, @east_map)
      refute has_element?(view, @west_map)
      refute_push_event(view, "basemap:fit", %{}, 50)
    end

    test "sends no event for the view the map already shows" do
      {:ok, view, _html} = live(build_conn(), "/vehicles?agency=near")

      render_patch(view, "/vehicles?agency=near")

      refute_push_event(view, "basemap:fit", %{}, 50)
    end
  end
end
