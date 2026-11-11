defmodule Gobusgo.Intersections.MergeTest do
  # Merges hand-written shared nodes into intersections.
  use ExUnit.Case, async: true

  alias Gobusgo.Intersections.Merge

  @pine_third ["3RD AVE", "PINE ST"]

  defp node(id, {lat, lon}, keys),
    do: %{id: id, lat_microdegrees: lat, lon_microdegrees: lon, keys: keys}

  test "merges the nodes of one pair within 150 m at the mean of their positions" do
    nodes = [
      node(1, {47_610_000, -122_337_000}, @pine_third),
      node(2, {47_610_200, -122_337_000}, @pine_third)
    ]

    assert %{
             intersections: [
               %{
                 first: "3RD AVE",
                 second: "PINE ST",
                 lat_microdegrees: 47_610_100,
                 lon_microdegrees: -122_337_000
               }
             ],
             pair_count: 1
           } = Merge.run(nodes)
  end

  test "keeps the nodes of one pair more than 150 m apart as two intersections" do
    nodes = [
      node(1, {47_610_000, -122_337_000}, @pine_third),
      node(2, {47_612_000, -122_337_000}, @pine_third)
    ]

    assert %{intersections: [_first, _second], pair_count: 1} = Merge.run(nodes)
  end

  test "makes a crossing of every pair of the keys through a node" do
    nodes = [node(1, {47_610_000, -122_337_000}, ["A ST", "B ST", "C ST"])]

    assert %{intersections: intersections, pair_count: 3} = Merge.run(nodes)

    assert Enum.map(intersections, &{&1.first, &1.second}) ==
             [{"A ST", "B ST"}, {"A ST", "C ST"}, {"B ST", "C ST"}]
  end

  test "does not depend on the order of the nodes" do
    nodes = [
      node(1, {47_610_000, -122_337_000}, @pine_third),
      node(2, {47_610_300, -122_337_000}, @pine_third),
      node(3, {47_610_600, -122_337_000}, @pine_third)
    ]

    assert Merge.run(nodes) == Merge.run(Enum.reverse(nodes))
  end

  test "makes nothing of no nodes" do
    assert Merge.run([]) == %{intersections: [], pair_count: 0}
  end
end
