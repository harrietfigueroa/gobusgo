defmodule Gobusgo.Pace.PathSourceTest do
  # Checks that a trip's path is prepared for learning from a polyline and
  # stop positions, with the band the trip's first departure picks.
  use ExUnit.Case, async: true

  alias Gobusgo.Pace.PathSource
  alias Gobusgo.Polyline

  @polyline Polyline.encode([[-122.34, 47.6], [-122.33, 47.6]])
  @stop_positions %{"a" => {47.6, -122.34}, "b" => {47.6, -122.33}}

  defp stop_time(stop_id, seconds) do
    %{
      stop_id: stop_id,
      arrival_s: seconds,
      departure_s: seconds,
      arrival_enabled: true,
      departure_enabled: true
    }
  end

  defp trip(first_departure_s) do
    %{
      id: "t",
      stop_times: [stop_time("a", first_departure_s), stop_time("b", first_departure_s + 600)]
    }
  end

  defp build(overrides) do
    PathSource.build(
      Map.merge(
        %{polylines: [@polyline], stop_positions: @stop_positions, trip: trip(7 * 3600)},
        overrides
      )
    )
  end

  test "prepares the path the trip follows, in the band of its first departure" do
    assert {:ok, %{band: 1, length_m: length_m}} = build(%{})
    assert_in_delta length_m, 750, 5
  end

  test "takes the band from the trip's first departure" do
    assert {:ok, %{band: 4}} = build(%{trip: trip(20 * 3600)})
  end

  test "has no path where a stop has no position" do
    assert build(%{stop_positions: %{"a" => {47.6, -122.34}}}) == :unavailable
  end

  test "has no path for a trip with no stop time" do
    assert build(%{trip: %{id: "t", stop_times: []}}) == :unavailable
  end
end
