defmodule Gobusgo.OneBusAway.AgencyCoverageTest do
  # Verifies the coverage geometry as pure functions over literal coverage:
  # the bounds of one coverage entry, the coverage that has no bounds, and
  # the buffered, merged regions of a list of agencies, including the twelve
  # coverage entries the live server returned.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.AgencyCoverage

  @delta_degrees 1.0e-9
  @meters_per_latitude_degree 111_320

  # The `data.list` of the agencies-with-coverage response fetched on
  # 2026-10-03, as {agency id, lat, lon, latSpan, lonSpan}.
  @live_coverage [
    {"1", 47.527353000000005, -122.1462285, 0.6764719999999969, 0.7207869999999872},
    {"23", 47.613395499999996, -122.3263055, 0.02854099999999704, 0.024529000000001133},
    {"3", 47.229401, -122.4183365, 0.3209319999999991, 0.4140730000000019},
    {"6289", 0.0, 0.0, 0.0, 0.0},
    {"29", 47.94702, -121.99285549999999, 0.6630380000000002, 0.7837090000000018},
    {"19", 47.047053, -122.73018450000001, 0.22802599999999984, 0.4938849999999917},
    {"95", 47.951749, -122.65587500000001, 1.2923619999999971, 0.7177500000000094},
    {"51", 47.786334499999995, -122.290815, 0.3772250000000028, 0.18711600000000317},
    {"40", 47.5346645, -122.32945649999999, 0.8893070000000023, 0.6211330000000004},
    {"96", 47.616654499999996, -122.3434575, 0.009216999999999587, 0.012994999999989432},
    {"97", 47.9448935, -122.24544, 0.12988500000000158, 0.12188199999999938},
    {"20", 47.633275, -122.5951815, 0.44307400000000285, 0.5125170000000026}
  ]

  defp coverage(lat, lon, lat_span, lon_span) do
    %{lat: lat, lon: lon, lat_span: lat_span, lon_span: lon_span}
  end

  defp agency(id, coverage), do: %{id: id, coverage: coverage}

  defp assert_bounds(actual, expected) do
    for edge <- [:south, :west, :north, :east] do
      assert_in_delta Map.fetch!(actual, edge), Map.fetch!(expected, edge), @delta_degrees
    end
  end

  describe "bounds/1" do
    test "places the edges half a span from the center" do
      assert AgencyCoverage.bounds(coverage(47.5, -122.0, 1.0, 0.5)) ==
               {:ok, %{south: 47.0, west: -122.25, north: 48.0, east: -121.75}}
    end

    test "returns a point for a center with zero spans" do
      assert AgencyCoverage.bounds(coverage(47.5, -122.0, 0, 0)) ==
               {:ok, %{south: 47.5, west: -122.0, north: 47.5, east: -122.0}}
    end

    for {description, coverage, reason} <- [
          {"all zeros", %{lat: 0.0, lon: 0.0, lat_span: 0.0, lon_span: 0.0}, :coverage_missing},
          {"integer zeros", %{lat: 0, lon: 0, lat_span: 0, lon_span: 0}, :coverage_missing},
          {"a negative latitude span", %{lat: 47.5, lon: -122.0, lat_span: -1.0, lon_span: 0.5},
           {:coverage_invalid, :lat_span}},
          {"a negative longitude span", %{lat: 47.5, lon: -122.0, lat_span: 1.0, lon_span: -0.5},
           {:coverage_invalid, :lon_span}},
          {"a north edge past the pole", %{lat: 89.5, lon: -122.0, lat_span: 2.0, lon_span: 0.5},
           {:coverage_invalid, :lat}},
          {"a south edge past the pole", %{lat: -89.5, lon: -122.0, lat_span: 2.0, lon_span: 0.5},
           {:coverage_invalid, :lat}},
          {"an east edge past the antimeridian",
           %{lat: 47.5, lon: 179.5, lat_span: 1.0, lon_span: 2.0}, {:coverage_invalid, :lon}},
          {"a west edge past the antimeridian",
           %{lat: 47.5, lon: -179.5, lat_span: 1.0, lon_span: 2.0}, {:coverage_invalid, :lon}}
        ] do
      test "returns #{inspect(reason)} for #{description}" do
        assert AgencyCoverage.bounds(unquote(Macro.escape(coverage))) ==
                 {:error, unquote(Macro.escape(reason))}
      end
    end
  end

  describe "extract_regions/2" do
    test "keeps each agency's own bounds, in agency identifier order" do
      agencies = [
        agency("b", coverage(10.0, 10.0, 2.0, 2.0)),
        agency("a", coverage(47.5, -122.0, 1.0, 0.5))
      ]

      assert AgencyCoverage.extract_regions(agencies, 5_000).agencies == [
               %{
                 agency_id: "a",
                 bounds: %{south: 47.0, west: -122.25, north: 48.0, east: -121.75}
               },
               %{agency_id: "b", bounds: %{south: 9.0, west: 9.0, north: 11.0, east: 11.0}}
             ]
    end

    test "keeps areas that stay apart as one region each, ordered west to east" do
      agencies = [
        agency("east", coverage(10.0, 30.0, 2.0, 2.0)),
        agency("west", coverage(10.0, 10.0, 2.0, 2.0))
      ]

      assert AgencyCoverage.extract_regions(agencies, 0).regions == [
               %{agency_ids: ["west"], bounds: %{south: 9.0, west: 9.0, north: 11.0, east: 11.0}},
               %{agency_ids: ["east"], bounds: %{south: 9.0, west: 29.0, north: 11.0, east: 31.0}}
             ]
    end

    test "combines overlapping areas into the bounds that hold both" do
      agencies = [
        agency("a", coverage(10.0, 10.0, 2.0, 2.0)),
        agency("b", coverage(11.0, 11.5, 2.0, 2.0))
      ]

      assert AgencyCoverage.extract_regions(agencies, 0).regions == [
               %{
                 agency_ids: ["a", "b"],
                 bounds: %{south: 9.0, west: 9.0, north: 12.0, east: 12.5}
               }
             ]
    end

    test "combines two regions that a later area bridges" do
      agencies = [
        agency("a", coverage(10.0, 10.0, 2.0, 2.0)),
        agency("c", coverage(10.0, 14.0, 2.0, 2.0)),
        agency("b", coverage(10.0, 12.0, 2.0, 3.0))
      ]

      assert AgencyCoverage.extract_regions(agencies, 0).regions == [
               %{
                 agency_ids: ["a", "b", "c"],
                 bounds: %{south: 9.0, west: 9.0, north: 11.0, east: 15.0}
               }
             ]
    end

    test "combines a region with one its growth reaches" do
      # "c" sits apart from "a" and from "b", and inside the bounds that hold
      # both, so combining "a" and "b" has to take "c" in as well.
      agencies = [
        agency("a", coverage(10.0, 10.0, 2.0, 2.0)),
        agency("c", coverage(13.5, 9.5, 0.5, 0.5)),
        agency("b", coverage(12.5, 11.5, 4.0, 2.0))
      ]

      assert [%{agency_ids: ["a", "b", "c"]}] =
               AgencyCoverage.extract_regions(agencies, 0).regions
    end

    test "buffers every edge, the east and west ones by the distance at the wider latitude" do
      [%{bounds: bounds}] =
        AgencyCoverage.extract_regions([agency("a", coverage(47.5, -122.0, 1.0, 0.5))], 5_000).regions

      latitude_degrees = 5_000 / @meters_per_latitude_degree
      north = 48.0 + latitude_degrees
      longitude_degrees = latitude_degrees / :math.cos(north * :math.pi() / 180)

      assert_bounds(bounds, %{
        south: 47.0 - latitude_degrees,
        west: -122.25 - longitude_degrees,
        north: north,
        east: -121.75 + longitude_degrees
      })
    end

    test "combines areas whose buffers overlap" do
      agencies = [
        agency("a", coverage(10.0, 10.0, 2.0, 2.0)),
        agency("b", coverage(10.0, 12.05, 2.0, 2.0))
      ]

      assert [_west, _east] = AgencyCoverage.extract_regions(agencies, 0).regions
      assert [%{agency_ids: ["a", "b"]}] = AgencyCoverage.extract_regions(agencies, 5_000).regions
    end

    test "keeps a buffered region inside the valid latitudes and longitudes" do
      agencies = [agency("a", coverage(89.5, 179.5, 1.0, 1.0))]

      assert [%{bounds: %{south: south, west: -180.0, north: 90.0, east: 180.0}}] =
               AgencyCoverage.extract_regions(agencies, 5_000).regions

      assert south < 89.0
    end

    test "leaves an agency without usable coverage out of the regions and names it" do
      agencies = [
        agency("b", coverage(47.5, -122.0, -1.0, 0.5)),
        agency("a", coverage(0.0, 0.0, 0.0, 0.0)),
        agency("c", coverage(10.0, 10.0, 2.0, 2.0))
      ]

      extract = AgencyCoverage.extract_regions(agencies, 0)

      assert extract.skipped == [
               %{agency_id: "a", reason: :coverage_missing},
               %{agency_id: "b", reason: {:coverage_invalid, :lat_span}}
             ]

      assert Enum.map(extract.agencies, & &1.agency_id) == ["c"]
      assert Enum.map(extract.regions, & &1.agency_ids) == [["c"]]
    end

    test "returns no region for no agency" do
      assert AgencyCoverage.extract_regions([], 5_000) == %{
               agencies: [],
               regions: [],
               skipped: []
             }
    end

    test "combines the live Puget Sound coverage into one region and skips the agency without one" do
      agencies =
        for {id, lat, lon, lat_span, lon_span} <- @live_coverage do
          agency(id, coverage(lat, lon, lat_span, lon_span))
        end

      extract = AgencyCoverage.extract_regions(agencies, 0)

      assert extract.skipped == [%{agency_id: "6289", reason: :coverage_missing}]
      assert [%{agency_ids: agency_ids, bounds: bounds}] = extract.regions
      assert agency_ids == Enum.sort(for {id, _, _, _, _} <- @live_coverage, id != "6289", do: id)

      assert_bounds(bounds, %{
        south: 47.047053 - 0.22802599999999984 / 2,
        west: -122.65587500000001 - 0.7177500000000094 / 2,
        north: 47.951749 + 1.2923619999999971 / 2,
        east: -121.99285549999999 + 0.7837090000000018 / 2
      })
    end

    for {description, agencies, buffer_meters, pattern} <- [
          {"a negative buffer", [], -1, ~r/buffer_meters/},
          {"a fractional buffer", [], 1.5, ~r/buffer_meters/},
          {"a buffer above the bound", [], 100_001, ~r/buffer_meters/},
          {"more agencies than the bound",
           List.duplicate(
             %{id: "a", coverage: %{lat: 0, lon: 0, lat_span: 0, lon_span: 0}},
             1_001
           ), 0, ~r/agency count/}
        ] do
      test "raises for #{description}" do
        assert_raise AssertionError, unquote(Macro.escape(pattern)), fn ->
          AgencyCoverage.extract_regions(unquote(Macro.escape(agencies)), unquote(buffer_meters))
        end
      end
    end
  end
end
