defmodule Gobusgo.Places.SelectionTest do
  # Drives the selection over hand-written GeoJSON records of the shape
  # `osmium export -f geojsonseq -a type,id` writes, and reads what is kept,
  # what is counted, and why a record is left out.
  use ExUnit.Case, async: true

  alias Gobusgo.Places.Selection

  @bounds %{south: 47.0, west: -123.0, north: 48.0, east: -121.5}
  # A square of about 100 m by 100 m near 47.5 N, 122.3 W.
  @square [
    [-122.3, 47.5],
    [-122.3, 47.50090],
    [-122.29867, 47.50090],
    [-122.29867, 47.5],
    [-122.3, 47.5]
  ]

  defp feature(tags, geometry) do
    properties = Map.merge(%{"@type" => "node", "@id" => 1}, tags)
    JSON.encode!(%{"type" => "Feature", "properties" => properties, "geometry" => geometry})
  end

  defp point(lon, lat), do: %{"type" => "Point", "coordinates" => [lon, lat]}

  defp select_one(tags, geometry \\ point(-122.3, 47.5)) do
    Selection.select(feature(tags, geometry), @bounds)
  end

  describe "select/2" do
    test "keeps a named node with its category, position, and prominence" do
      tags = %{
        "name" => "Space Needle",
        "tourism" => "attraction",
        "wikidata" => "Q1",
        "wikipedia" => "en:x"
      }

      assert {:place, place} = select_one(tags)
      assert place.name == "Space Needle"
      assert place.category == "tourism"
      assert place.prominence == 140 + 40 + 15
      assert place.area == 0
      assert place.lat == 47.5
      assert place.lon == -122.3
    end

    test "reads the street address and the settlement kind of a feature" do
      tags = %{
        "name" => "Cafe",
        "amenity" => "cafe",
        "addr:housenumber" => "400",
        "addr:street" => "Pine Street"
      }

      assert {:place, %{address: "400 Pine Street", settlement: ""}} = select_one(tags)

      assert {:place, %{address: "", settlement: "suburb"}} =
               select_one(%{"name" => "Ballard", "place" => "suburb"})
    end

    test "caps prominence at 255" do
      tags = %{"name" => "Seattle", "place" => "city", "wikidata" => "Q1", "wikipedia" => "en:x"}
      assert {:place, %{prominence: 255}} = select_one(tags)
    end

    test "places a closed way at its centroid with an area score" do
      geometry = %{"type" => "Polygon", "coordinates" => [@square]}
      assert {:place, place} = select_one(%{"name" => "Hall", "building" => "yes"}, geometry)
      assert_in_delta place.lat, 47.5 + 0.00045, 1.0e-6
      assert_in_delta place.lon, -122.2993350, 1.0e-6
      assert place.category == "building"
      assert place.area > 5_000 and place.area < 15_000
      assert place.area_score == round(8 * :math.log10(place.area / 1000))
    end

    test "scores an area under 1,000 m2 as 0" do
      small = [
        [-122.3, 47.5],
        [-122.3, 47.50009],
        [-122.29987, 47.50009],
        [-122.29987, 47.5],
        [-122.3, 47.5]
      ]

      geometry = %{"type" => "Polygon", "coordinates" => [small]}

      assert {:place, %{area_score: 0}} =
               select_one(%{"name" => "Shed", "building" => "yes"}, geometry)
    end

    test "weights the outer rings of a multipolygon by area and ignores holes" do
      far = Enum.map(@square, fn [lon, lat] -> [lon + 0.01, lat] end)

      hole = [
        [-122.2999, 47.5001],
        [-122.2999, 47.5002],
        [-122.2998, 47.5002],
        [-122.2999, 47.5001]
      ]

      geometry = %{"type" => "MultiPolygon", "coordinates" => [[@square, hole], [far]]}

      assert {:place, place} = select_one(%{"name" => "Campus", "leisure" => "park"}, geometry)
      assert_in_delta place.lon, -122.2993350 + 0.005, 1.0e-6
      assert place.area > 15_000
    end

    test "keeps a record whose tag value holds a newline, as one place" do
      tags = %{"name" => "Line\nBreak", "amenity" => "library"}
      assert {:place, %{name: "Line Break"}} = select_one(tags)
    end

    test "cleans the name and cuts it to 200 characters" do
      long = String.duplicate("a", 250)
      assert {:place, %{name: name}} = select_one(%{"name" => long, "shop" => "mall"})
      assert String.length(name) == 200

      assert {:place, %{name: "A B C"}} = select_one(%{"name" => "  A;B\tC ", "shop" => "mall"})
    end

    test "collects aliases split on semicolons, distinct, and different from the name" do
      tags = %{
        "name" => "Central Library",
        "amenity" => "library",
        "alt_name" => "Main Library; Central Library;Main Library",
        "short_name" => "CL",
        "name:en" => "Library"
      }

      assert {:place, %{aliases: ["Main Library", "CL", "Library"]}} = select_one(tags)
    end

    test "leaves out a feature with no name" do
      assert select_one(%{"amenity" => "library"}) == {:skipped, :unnamed}
    end

    test "leaves out a feature of no category" do
      assert select_one(%{"name" => "A Road", "highway" => "residential"}) ==
               {:skipped, :excluded}
    end

    test "leaves out street furniture and parking" do
      assert select_one(%{"name" => "Lot 4", "amenity" => "parking"}) == {:skipped, :excluded}
    end

    test "leaves out a place whose position is outside the bounds" do
      assert select_one(%{"name" => "Portland", "place" => "city"}, point(-122.6, 45.5)) ==
               {:skipped, {:outside, "place"}}
    end

    test "leaves out a geometry that is not a point or an area" do
      line = %{"type" => "LineString", "coordinates" => [[-122.3, 47.5], [-122.3, 47.6]]}
      assert select_one(%{"name" => "Trail", "leisure" => "park"}, line) == {:skipped, :unusable}
    end

    test "leaves out a record that is not JSON" do
      assert Selection.select("{broken", @bounds) == {:skipped, :unusable}
    end

    for {tags, label} <- [
          {%{"highway" => "bus_stop"}, "a bus stop"},
          {%{"highway" => "bus_stop", "amenity" => "shelter"}, "a bus stop with a shelter"},
          {%{"highway" => "bus_stop", "shop" => "kiosk"}, "a bus stop with a kiosk"},
          {%{"public_transport" => "platform"}, "a platform"},
          {%{"public_transport" => "stop_position"}, "a stop position"},
          {%{"railway" => "platform"}, "a railway platform"},
          {%{"railway" => "tram_stop"}, "a tram stop"},
          {%{"railway" => "stop"}, "a railway stop"},
          {%{"railway" => "station", "public_transport" => "platform"},
           "a station tagged as platform"}
        ] do
      test "leaves out #{label} as a stop" do
        tags = Map.put(unquote(Macro.escape(tags)), "name", "3rd Ave & Pike")
        assert select_one(tags) == {:skipped, :stop}
      end
    end

    test "keeps stations" do
      for tags <- [
            %{"railway" => "station"},
            %{"railway" => "halt"},
            %{"public_transport" => "station"},
            %{"amenity" => "bus_station"},
            %{"amenity" => "ferry_terminal"},
            %{"aeroway" => "aerodrome"}
          ] do
        assert {:place, %{category: "station"}} = select_one(Map.put(tags, "name", "Hub"))
      end
    end
  end

  describe "run/2" do
    test "counts what is read, named, a stop, excluded, outside, unusable, and kept" do
      records = [
        feature(%{"name" => "Library", "amenity" => "library"}, point(-122.3, 47.5)),
        feature(%{"name" => "Cafe", "amenity" => "cafe"}, point(-122.31, 47.5)),
        feature(%{"amenity" => "library"}, point(-122.3, 47.5)),
        feature(%{"name" => "Stop", "highway" => "bus_stop"}, point(-122.3, 47.5)),
        feature(%{"name" => "Road", "highway" => "service"}, point(-122.3, 47.5)),
        feature(%{"name" => "Far", "amenity" => "library"}, point(-100.0, 47.5)),
        "{broken"
      ]

      assert {places, counts} = Selection.run(records ++ ["\n"], @bounds)
      assert Enum.map(places, & &1.name) |> Enum.sort() == ["Cafe", "Library"]

      assert counts == %{
               read: 7,
               named: 5,
               stops: 1,
               excluded: 1,
               outside: 1,
               unusable: 1,
               kept: 2,
               by_category: %{
                 "amenity" => %{kept: 1, outside: 1},
                 "food" => %{kept: 1, outside: 0}
               }
             }
    end
  end
end
