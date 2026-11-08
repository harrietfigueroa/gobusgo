defmodule Gobusgo.Routing.TransfersTest do
  # Verifies the walking links as a pure function of stop positions placed
  # by hand at known distances near Seattle, where a degree of latitude is
  # about 111,195 m.
  use ExUnit.Case, async: true

  alias Gobusgo.Routing.Transfers

  @lat 47.6
  @lon -122.33
  @degree_m 111_195

  defp north(meters), do: %{lat: @lat + meters / @degree_m, lon: @lon}

  test "joins two stops 299 m apart in both directions, at the walking speed rounded up" do
    links = Transfers.walking_links(["a", "b"], %{"a" => north(0), "b" => north(299)})

    assert links == [
             %{from_stop: 0, to_stop: 1, duration_s: 250},
             %{from_stop: 1, to_stop: 0, duration_s: 250}
           ]
  end

  test "joins no stops farther apart than the radius" do
    assert Transfers.walking_links(["a", "b"], %{"a" => north(0), "b" => north(450)}) == []
  end

  test "gives no link to a stop without a position" do
    assert Transfers.walking_links(["a", "b"], %{"a" => north(0)}) == []
  end

  test "finds a stop in the next cell over" do
    # The two stops straddle a cell edge: 10 m apart, on either side of a
    # multiple of the radius in latitude.
    edge_m = Float.ceil(@lat * @degree_m / 400) * 400 - @lat * @degree_m

    links =
      Transfers.walking_links(["a", "b"], %{"a" => north(edge_m - 5), "b" => north(edge_m + 5)})

    assert length(links) == 2
  end

  test "states the rules a reader applies" do
    assert Transfers.rules() == %{
             minimum_transfer_s: 120,
             walk_radius_m: 400,
             walk_speed_m_per_s: 1.2
           }
  end
end
