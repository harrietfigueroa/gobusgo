defmodule Gobusgo.PolylineTest do
  # Decodes literal encoded polylines and compares the points with the ones
  # they encode, including the worked example of the format's documentation
  # and strings that end inside a value.
  use ExUnit.Case, async: true

  alias Gobusgo.Polyline

  describe "encode/1" do
    # https://developers.google.com/maps/documentation/utilities/polylinealgorithm — checked 2026-10-14
    test "writes the documentation's example from its points, longitude first" do
      assert Polyline.encode([[-120.2, 38.5], [-120.95, 40.7], [-126.453, 43.252]]) ==
               "_p~iF~ps|U_ulLnnqC_mqNvxq`@"
    end

    test "writes nothing for no point" do
      assert Polyline.encode([]) == ""
    end

    test "writes points that decode to themselves at five decimal places" do
      points = [[-122.33207, 47.60621], [-122.33541, 47.60846], [-122.3, 47.7]]
      assert points |> Polyline.encode() |> Polyline.decode() == {:ok, points}
    end
  end

  describe "decode/1" do
    # https://developers.google.com/maps/documentation/utilities/polylinealgorithm — checked 2026-10-14
    test "returns the points of the documentation's example, longitude first" do
      assert Polyline.decode("_p~iF~ps|U_ulLnnqC_mqNvxq`@") ==
               {:ok, [[-120.2, 38.5], [-120.95, 40.7], [-126.453, 43.252]]}
    end

    test "returns no point for an empty string" do
      assert Polyline.decode("") == {:ok, []}
    end

    for {description, points} <- [
          {"inside a value", "_p~iF~ps|U_ulL"},
          {"between a latitude and its longitude", "_p~iF"},
          {"on a chunk that says another follows", "_p~iF~ps|U_"}
        ] do
      test "returns :truncated for a string that ends #{description}" do
        assert Polyline.decode(unquote(points)) == {:error, :truncated}
      end
    end

    test "returns :invalid_character for a character outside the format" do
      assert Polyline.decode("_p~iF ps|U") == {:error, :invalid_character}
    end
  end
end
