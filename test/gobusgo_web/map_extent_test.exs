defmodule GobusgoWeb.MapExtentTest do
  # Verifies the bounds a map fits around a set of positions as a pure
  # function: each case names the positions and the bounds they have to lie
  # within, and the bounds to fit.
  use ExUnit.Case, async: true

  alias GobusgoWeb.MapExtent

  @within %{south: 47.0, west: -123.0, north: 48.0, east: -122.0}

  defp bounds(positions), do: MapExtent.bounds(%{positions: positions, within: @within})

  test "is the box around the positions" do
    positions = [
      %{lat: 47.6, lon: -122.3},
      %{lat: 47.7, lon: -122.5},
      %{lat: 47.5, lon: -122.2}
    ]

    assert bounds(positions) == %{south: 47.5, west: -122.5, north: 47.7, east: -122.2}
  end

  test "is none for no position" do
    assert bounds([]) == nil
  end

  test "spans at least the shortest span around one position" do
    assert %{south: south, west: west, north: north, east: east} =
             bounds([%{lat: 47.6, lon: -122.3}])

    assert_in_delta north - south, MapExtent.span_degrees_min(), 1.0e-9
    assert_in_delta east - west, MapExtent.span_degrees_min(), 1.0e-9
    assert_in_delta (south + north) / 2, 47.6, 1.0e-9
    assert_in_delta (west + east) / 2, -122.3, 1.0e-9
  end

  test "widens only the side that is shorter than the shortest span" do
    assert %{south: 47.5, north: 47.7, west: west, east: east} =
             bounds([%{lat: 47.5, lon: -122.3}, %{lat: 47.7, lon: -122.3}])

    assert_in_delta east - west, MapExtent.span_degrees_min(), 1.0e-9
  end

  test "ends where the bounds it lies within end" do
    positions = [%{lat: 46.5, lon: -123.5}, %{lat: 47.5, lon: -122.5}]

    assert bounds(positions) == %{south: 47.0, west: -123.0, north: 47.5, east: -122.5}
  end

  test "is none for positions outside the bounds they have to lie within" do
    assert bounds([%{lat: 45.0, lon: -122.3}, %{lat: 45.2, lon: -122.1}]) == nil
  end
end
