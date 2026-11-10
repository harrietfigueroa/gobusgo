defmodule Gobusgo.Places.BoundsTest do
  use ExUnit.Case, async: true

  alias Gobusgo.Places.Bounds

  describe "parse/1" do
    test "reads south, west, north, east" do
      assert Bounds.parse("46.888124,-123.082727,48.642845,-121.533451") ==
               {:ok, %{south: 46.888124, west: -123.082727, north: 48.642845, east: -121.533451}}
    end

    for text <- [
          "1,2,3",
          "a,b,c,d",
          "48,-123,47,-121",
          "47,-121,48,-123",
          "47,-123,95,-121",
          "47,-123,48,-121,1",
          ""
        ] do
      test "refuses #{inspect(text)}" do
        assert Bounds.parse(unquote(text)) == {:error, :invalid_bounds}
      end
    end
  end

  describe "from_manifest/1" do
    test "is the union of the archives' bounds" do
      manifest = %{
        archives: [
          %{
            name: "a",
            bounds: %{south: 47.0, west: -123.0, north: 47.5, east: -122.0},
            offline: nil
          },
          %{
            name: "b",
            bounds: %{south: 46.5, west: -122.5, north: 48.0, east: -121.5},
            offline: nil
          }
        ]
      }

      assert Bounds.from_manifest(manifest) == %{
               south: 46.5,
               west: -123.0,
               north: 48.0,
               east: -121.5
             }
    end
  end

  describe "contains?/2" do
    test "includes the edges and excludes the rest" do
      bounds = %{south: 47.0, west: -123.0, north: 48.0, east: -122.0}
      assert Bounds.contains?(bounds, %{lat: 47.0, lon: -122.0})
      refute Bounds.contains?(bounds, %{lat: 46.99, lon: -122.5})
      refute Bounds.contains?(bounds, %{lat: 47.5, lon: -121.99})
    end
  end
end
