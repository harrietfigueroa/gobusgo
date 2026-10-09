defmodule GobusgoWeb.BasemapSourcesTest do
  # Verifies the basemap's sources and views as pure functions over a literal
  # manifest of two archives.
  use ExUnit.Case, async: true

  alias GobusgoWeb.BasemapSources

  @west_archive "basemap-20261004-01.pmtiles"
  @east_archive "basemap-20261004-02.pmtiles"
  @west_bounds %{south: 9.0, west: 9.0, north: 12.0, east: 12.5}
  @east_bounds %{south: 9.0, west: 29.0, north: 11.0, east: 31.0}
  @agency_bounds %{south: 10.0, west: 10.5, north: 12.0, east: 12.5}
  @manifest %{
    snapshot: "20261004",
    archives: [
      %{name: @west_archive, bounds: @west_bounds},
      %{name: @east_archive, bounds: @east_bounds}
    ],
    agencies: [
      %{agency_id: "near-west", archive: @west_archive, bounds: @agency_bounds},
      %{agency_id: "east", archive: @east_archive, bounds: @east_bounds}
    ]
  }

  describe "sources/1" do
    test "names the archive, the fonts, and the sprites by path, with the attribution" do
      assert BasemapSources.sources(@west_archive) == %{
               archive_url: "/basemap/basemap-20261004-01.pmtiles",
               fonts_url: "/vendor/basemaps-assets/fonts",
               sprites_url: "/vendor/basemaps-assets/sprites/v4",
               attribution:
                 ~s(<a href="https://www.openstreetmap.org/copyright">&copy; OpenStreetMap</a>)
             }
    end
  end

  describe "view/2" do
    test "fits the first archive whole when no agency is chosen" do
      assert BasemapSources.view(@manifest, nil) == %{
               archive: @west_archive,
               sources: BasemapSources.sources(@west_archive),
               bounds: @west_bounds,
               archive_bounds: @west_bounds,
               agency_id: nil,
               agency_ids: ["near-west", "east"]
             }
    end

    test "names the bounds of the whole archive beside a chosen agency's coverage" do
      assert %{bounds: @agency_bounds, archive_bounds: @west_bounds} =
               BasemapSources.view(@manifest, "near-west")
    end

    test "names the bounds of the archive that holds the chosen agency" do
      assert %{archive_bounds: @east_bounds} = BasemapSources.view(@manifest, "east")
    end

    test "fits the chosen agency's own coverage" do
      assert %{archive: @west_archive, bounds: @agency_bounds, agency_id: "near-west"} =
               BasemapSources.view(@manifest, "near-west")
    end

    test "draws from the archive that holds the chosen agency" do
      assert %{archive: @east_archive, bounds: @east_bounds, agency_id: "east", sources: sources} =
               BasemapSources.view(@manifest, "east")

      assert sources.archive_url == "/basemap/basemap-20261004-02.pmtiles"
    end

    test "fits the first archive whole for an agency the manifest does not hold" do
      assert %{archive: @west_archive, bounds: @west_bounds, agency_id: nil} =
               BasemapSources.view(@manifest, "6289")
    end
  end
end
