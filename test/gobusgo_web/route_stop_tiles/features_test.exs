defmodule GobusgoWeb.RouteStopTiles.FeaturesTest do
  # Builds the GeoJSON features of literal lines and stop markers and decodes
  # them back, so each test reads what tippecanoe is given: the geometry, the
  # properties, and the zoom a stop starts at.
  use ExUnit.Case, async: true

  alias GobusgoWeb.RouteStopTiles.Features

  # Two points, (38.5, -120.2) and (40.7, -120.95).
  @points "_p~iF~ps|U_ulLnnqC"
  @line %{
    id: "1_100",
    color: "#ff0000",
    short_name: "10",
    long_name: "Capitol Hill",
    agency_name: "Metro",
    polylines: [@points]
  }
  @marker %{
    id: "1_500",
    lat: 47.6,
    lon: -122.3,
    name: "Pine St & 3rd Ave",
    code: "500",
    direction: "N",
    routes: ["10", "11"],
    agencies: ["Metro"]
  }

  defp route(line), do: line |> Features.route() |> decode()

  defp stop(marker, route_ids \\ ["1_100", "1_110"]),
    do: decode(Features.stop(%{marker: marker, route_ids: route_ids}))

  defp decode({:ok, encoded}), do: JSON.decode!(encoded)
  defp decode(other), do: other

  describe "route/1" do
    test "is one multi-line of the route's polylines, longitude first" do
      assert route(@line)["geometry"] == %{
               "type" => "MultiLineString",
               "coordinates" => [[[-120.2, 38.5], [-120.95, 40.7]]]
             }
    end

    test "holds the route's identifier, color, and names" do
      assert route(@line)["properties"] == %{
               "routeId" => "1_100",
               "color" => "#ff0000",
               "shortName" => "10",
               "longName" => "Capitol Hill",
               "agencyName" => "Metro"
             }
    end

    test "leaves out a name the route does not have" do
      properties = route(%{@line | short_name: nil, agency_name: nil})["properties"]

      assert Map.keys(properties) == ["color", "longName", "routeId"]
    end

    test "leaves out a polyline of fewer than two points" do
      line = %{@line | polylines: [@points, "_p~iF~ps|U"]}

      assert length(route(line)["geometry"]["coordinates"]) == 1
    end

    for {description, polylines} <- [
          {"no polyline", []},
          {"only polylines of one point", ["_p~iF~ps|U"]}
        ] do
      test "is :no_geometry for a route with #{description}" do
        assert Features.route(%{@line | polylines: unquote(polylines)}) == :no_geometry
      end
    end

    test "is the reason for a polyline that does not decode" do
      assert Features.route(%{@line | polylines: ["_p~iF~ps|U_ulL"]}) ==
               {:error, {:polyline, :truncated}}
    end
  end

  describe "stop/1" do
    test "is a point at the stop's position, longitude first" do
      assert stop(@marker)["geometry"] == %{"type" => "Point", "coordinates" => [-122.3, 47.6]}
    end

    test "starts at the zoom a map first draws stops at" do
      assert stop(@marker)["tippecanoe"] == %{"minzoom" => Features.stop_zoom_min()}
    end

    test "holds the stop's texts and the identifiers of its drawn routes" do
      assert stop(@marker)["properties"] == %{
               "stopId" => "1_500",
               "name" => "Pine St & 3rd Ave",
               "code" => "500",
               "direction" => "N",
               "routes" => "10, 11",
               "agencies" => "Metro",
               "routeIds" => ",1_100,1_110,",
               "label" => "10 11\nN · Metro"
             }
    end

    test "leaves out a code and a direction the stop does not have" do
      properties = stop(%{@marker | code: nil, direction: nil})["properties"]

      assert Map.has_key?(properties, "code") == false
      assert Map.has_key?(properties, "direction") == false
    end
  end

  describe "label/1" do
    for {description, marker, label} <- [
          {"routes, direction, and agencies",
           %{routes: ["10"], direction: "N", agencies: ["Metro"]}, "10\nN · Metro"},
          {"more routes than one line names",
           %{routes: ~w(1 2 3 4 5 6), direction: nil, agencies: []}, "1 2 3 4 +2"},
          {"four routes", %{routes: ~w(1 2 3 4), direction: nil, agencies: []}, "1 2 3 4"},
          {"two agencies and no direction",
           %{routes: [], direction: nil, agencies: ["Metro", "Sound Transit"]},
           "Metro, Sound Transit"},
          {"an empty direction", %{routes: ["10"], direction: "", agencies: []}, "10"},
          {"nothing", %{routes: [], direction: nil, agencies: []}, ""}
        ] do
      test "names #{description}" do
        assert Features.label(unquote(Macro.escape(marker))) == unquote(label)
      end
    end
  end
end
