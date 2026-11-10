defmodule Gobusgo.Math.GeodesyTest do
  # Checks the geodesy module against values known by construction on the
  # sphere of the mean radius, and checks that the browser's geodesy module
  # declares the same radius, by reading its source.
  use ExUnit.Case, async: true

  alias Gobusgo.Math.Geodesy

  @tolerance_meters 1.0e-6
  @browser_geodesy_path "assets/js/math/geodesy.js"

  defp meters_per_degree, do: :math.pi() * Geodesy.earth_radius_meters() / 180

  describe "distance_meters/2" do
    for {name, from, to, meters} <- [
          {"one position", %{lat: 47.6062, lon: -122.3321}, %{lat: 47.6062, lon: -122.3321},
           :zero},
          {"a degree of the prime meridian", %{lat: 0, lon: 0}, %{lat: 1, lon: 0}, :degree},
          {"a degree of the equator", %{lat: 0, lon: 0}, %{lat: 0, lon: 1}, :degree},
          {"a degree across the antimeridian", %{lat: 0, lon: 179.5}, %{lat: 0, lon: -179.5},
           :degree},
          {"a quarter of the equator", %{lat: 0, lon: 0}, %{lat: 0, lon: 90}, :quarter},
          {"antipodes", %{lat: 0, lon: 0}, %{lat: 0, lon: 180}, :half}
        ] do
      test "measures #{name}" do
        expected =
          case unquote(meters) do
            :zero -> 0.0
            :degree -> meters_per_degree()
            :quarter -> :math.pi() * Geodesy.earth_radius_meters() / 2
            :half -> :math.pi() * Geodesy.earth_radius_meters()
          end

        actual = Geodesy.distance_meters(unquote(Macro.escape(from)), unquote(Macro.escape(to)))
        assert_in_delta actual, expected, @tolerance_meters
      end
    end

    # Erlang raises on an arcsine past 1 where JavaScript returns NaN. This
    # pair's haversine sum rounds to 1.0000000000000002, past 1.
    test "measures an antipodal pair whose haversine sum rounds past 1" do
      source = %{lat: -3.0317, lon: -22.5901}
      antipode = %{lat: 3.0317, lon: 157.4099}
      half = :math.pi() * Geodesy.earth_radius_meters()
      assert_in_delta Geodesy.distance_meters(source, antipode), half, 1.0
    end

    test "is the same either way" do
      seattle = %{lat: 47.6062, lon: -122.3321}
      tacoma = %{lat: 47.2529, lon: -122.4443}
      assert Geodesy.distance_meters(seattle, tacoma) == Geodesy.distance_meters(tacoma, seattle)
    end
  end

  describe "radians/1 and degrees/1" do
    test "convert a half turn" do
      assert Geodesy.radians(180) == :math.pi()
      assert Geodesy.degrees(:math.pi()) == 180.0
    end

    test "multiply by pi before dividing by 180" do
      assert Geodesy.radians(47.6062) == 47.6062 * :math.pi() / 180
    end
  end

  test "the browser's geodesy module declares the same Earth radius" do
    source = File.read!(@browser_geodesy_path)

    [radius_text] =
      Regex.run(~r/^export const EARTH_RADIUS_METERS = ([0-9.]+)$/m, source,
        capture: :all_but_first
      )

    assert String.to_float(radius_text) == Geodesy.earth_radius_meters()
  end
end
