defmodule Gobusgo.Basemap.ExtractPlanTest do
  # Verifies the extract plan as pure functions over literal agencies: the
  # archives a list of agencies needs, the archive each agency reads, the
  # arguments of one extraction, and the manifest that records a finished run.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Basemap.ExtractPlan

  @snapshot "20261004"

  @west {"west", {10.0, 10.0, 2.0, 2.0}}
  @east {"east", {10.0, 30.0, 2.0, 2.0}}
  @near_west {"near-west", {11.0, 11.5, 2.0, 2.0}}
  @missing {"missing", {0.0, 0.0, 0.0, 0.0}}

  defp agency({id, {lat, lon, lat_span, lon_span}}) do
    %{id: id, coverage: %{lat: lat, lon: lon, lat_span: lat_span, lon_span: lon_span}}
  end

  defp plan(agencies, snapshot \\ @snapshot, offline_zoom_max \\ nil) do
    ExtractPlan.build(%{
      agencies: Enum.map(agencies, &agency/1),
      snapshot: snapshot,
      offline_zoom_max: offline_zoom_max
    })
  end

  describe "valid_snapshot?/1" do
    for {snapshot, expected} <- [
          {"20261004", true},
          {"2026100", false},
          {"202610045", false},
          {"2026-10-04", false},
          {"20261004.pmtiles", false},
          {"20261004\n", false},
          {"", false}
        ] do
      test "is #{expected} for #{inspect(snapshot)}" do
        assert ExtractPlan.valid_snapshot?(unquote(snapshot)) == unquote(expected)
      end
    end
  end

  describe "valid_offline_zoom_max?/1" do
    for {zoom, expected} <- [
          {13, true},
          {0, true},
          {14, true},
          {15, false},
          {-1, false},
          {13.0, false},
          {"13", false}
        ] do
      test "is #{expected} for #{inspect(zoom)}" do
        assert ExtractPlan.valid_offline_zoom_max?(unquote(zoom)) == unquote(expected)
      end
    end
  end

  describe "build/1" do
    test "names the source build, the zoom range, and the buffer" do
      assert %{
               snapshot: "20261004",
               source_url: "https://build.protomaps.com/20261004.pmtiles",
               zoom_min: 0,
               zoom_max: 15,
               buffer_meters: 5_000
             } = plan([@west])
    end

    test "plans one archive per region, numbered west to east" do
      assert [
               %{name: "basemap-20261004-01.pmtiles", agency_ids: ["west"]},
               %{name: "basemap-20261004-02.pmtiles", agency_ids: ["east"]}
             ] = plan([@east, @west]).archives
    end

    test "plans one archive for agencies whose coverage overlaps" do
      assert [%{name: "basemap-20261004-01.pmtiles", agency_ids: ["near-west", "west"]}] =
               plan([@west, @near_west]).archives
    end

    test "gives an archive the buffered bounds of its region" do
      [%{bounds: bounds}] = plan([@west]).archives

      assert bounds.south < 9.0
      assert bounds.west < 9.0
      assert bounds.north > 11.0
      assert bounds.east > 11.0
    end

    test "names the archive that holds each agency, with the agency's own bounds" do
      assert plan([@east, @west, @near_west]).agencies == [
               %{
                 agency_id: "east",
                 archive: "basemap-20261004-02.pmtiles",
                 bounds: %{south: 9.0, west: 29.0, north: 11.0, east: 31.0}
               },
               %{
                 agency_id: "near-west",
                 archive: "basemap-20261004-01.pmtiles",
                 bounds: %{south: 10.0, west: 10.5, north: 12.0, east: 12.5}
               },
               %{
                 agency_id: "west",
                 archive: "basemap-20261004-01.pmtiles",
                 bounds: %{south: 9.0, west: 9.0, north: 11.0, east: 11.0}
               }
             ]
    end

    test "leaves an agency without coverage out of the archives and names it" do
      plan = plan([@west, @missing])

      assert plan.skipped == [%{agency_id: "missing", reason: :coverage_missing}]
      assert Enum.map(plan.agencies, & &1.agency_id) == ["west"]
      assert Enum.map(plan.archives, & &1.agency_ids) == [["west"]]
    end

    test "plans no archive for no agency" do
      assert %{archives: [], agencies: [], skipped: []} = plan([])
    end

    test "raises for a snapshot that is not a build date" do
      assert_raise AssertionError, ~r/snapshot/, fn ->
        plan([@west], "latest")
      end
    end

    test "plans no offline extract when no offline zoom bound is given" do
      assert [%{offline: nil}] = plan([@west]).archives
    end

    test "plans an offline extract of each archive, named for its zoom bound" do
      assert [
               %{
                 name: "basemap-20261004-01.pmtiles",
                 offline: %{name: "basemap-20261004-01-z13.pmtiles", zoom_max: 13}
               },
               %{
                 name: "basemap-20261004-02.pmtiles",
                 offline: %{name: "basemap-20261004-02-z13.pmtiles", zoom_max: 13}
               }
             ] = plan([@east, @west], @snapshot, 13).archives
    end

    test "raises for an offline zoom bound that is not below the archive's" do
      assert_raise AssertionError, ~r/offline zoom/, fn ->
        plan([@west], @snapshot, 15)
      end
    end
  end

  describe "extract_arguments/1" do
    test "asks for the archive's bounds, west and south first, up to the zoom bound" do
      plan = plan([@west])
      [%{bounds: bounds} = archive] = plan.archives

      assert ExtractPlan.extract_arguments(%{
               plan: plan,
               archive: archive,
               output_path: "/out/basemap.pmtiles"
             }) == [
               "extract",
               "https://build.protomaps.com/20261004.pmtiles",
               "/out/basemap.pmtiles",
               "--bbox=#{bounds.west},#{bounds.south},#{bounds.east},#{bounds.north}",
               "--maxzoom=15"
             ]
    end
  end

  describe "offline_extract_arguments/1" do
    test "cuts the zooms up to the offline bound out of the extracted archive" do
      [%{offline: offline}] = plan([@west], @snapshot, 13).archives

      assert ExtractPlan.offline_extract_arguments(%{
               offline: offline,
               archive_path: "/out/basemap-20261004-01.pmtiles",
               output_path: "/out/basemap-20261004-01-z13.pmtiles.partial"
             }) == [
               "extract",
               "/out/basemap-20261004-01.pmtiles",
               "/out/basemap-20261004-01-z13.pmtiles.partial",
               "--maxzoom=13"
             ]
    end
  end

  describe "manifest/1" do
    test "records the source, the zoom range, every archive with its size, and every agency" do
      plan = plan([@west, @missing])
      [%{bounds: bounds}] = plan.archives

      assert ExtractPlan.manifest(%{
               plan: plan,
               archive_bytes: %{"basemap-20261004-01.pmtiles" => 1_234},
               response_destination: "raw/oba/agencies-with-coverage/dt=2026-10-03/a.json.gz"
             }) == %{
               "snapshot" => "20261004",
               "sourceUrl" => "https://build.protomaps.com/20261004.pmtiles",
               "sourceResponse" => "raw/oba/agencies-with-coverage/dt=2026-10-03/a.json.gz",
               "zoomMin" => 0,
               "zoomMax" => 15,
               "bufferMeters" => 5_000,
               "archives" => [
                 %{
                   "name" => "basemap-20261004-01.pmtiles",
                   "bytes" => 1_234,
                   "agencyIds" => ["west"],
                   "bounds" => %{
                     "south" => bounds.south,
                     "west" => bounds.west,
                     "north" => bounds.north,
                     "east" => bounds.east
                   }
                 }
               ],
               "agencies" => [
                 %{
                   "agencyId" => "west",
                   "archive" => "basemap-20261004-01.pmtiles",
                   "bounds" => %{"south" => 9.0, "west" => 9.0, "north" => 11.0, "east" => 11.0}
                 }
               ],
               "skipped" => [%{"agencyId" => "missing", "reason" => "coverage_missing"}]
             }
    end

    test "records each archive's offline extract with its size and zoom bound" do
      plan = plan([@west], @snapshot, 13)

      assert %{
               "archives" => [
                 %{
                   "name" => "basemap-20261004-01.pmtiles",
                   "offline" => %{
                     "name" => "basemap-20261004-01-z13.pmtiles",
                     "bytes" => 345,
                     "zoomMax" => 13
                   }
                 }
               ]
             } =
               ExtractPlan.manifest(%{
                 plan: plan,
                 archive_bytes: %{
                   "basemap-20261004-01.pmtiles" => 1_234,
                   "basemap-20261004-01-z13.pmtiles" => 345
                 },
                 response_destination: "a"
               })
    end

    test "names the field of an invalid coverage" do
      plan = plan([{"bad", {47.5, -122.0, -1.0, 0.5}}])

      assert %{"skipped" => [%{"agencyId" => "bad", "reason" => "coverage_invalid:lat_span"}]} =
               ExtractPlan.manifest(%{plan: plan, archive_bytes: %{}, response_destination: "a"})
    end

    test "raises for an archive without a size" do
      assert_raise AssertionError, ~r/basemap-20261004-01.pmtiles/, fn ->
        ExtractPlan.manifest(%{
          plan: plan([@west]),
          archive_bytes: %{},
          response_destination: "a"
        })
      end
    end
  end
end
