defmodule Gobusgo.Intersections.SelectionTest do
  # Reads the hand-written OPL export of Gobusgo.Test.IntersectionOpl, with
  # and without service roads, and checks the nodes and the counts.
  use ExUnit.Case, async: true

  alias Gobusgo.Intersections.Selection
  alias Gobusgo.Test.IntersectionOpl

  defp run(service_roads, lines \\ IntersectionOpl.lines_fun()) do
    Selection.run(%{
      lines: lines,
      bounds: IntersectionOpl.bounds(),
      service_roads: service_roads
    })
  end

  test "finds the nodes that two differently named roads share, inside the bounds" do
    %{nodes: nodes} = run(false)

    assert Enum.map(nodes, &{&1.id, &1.keys}) == [
             {1, ["3RD AVE", "PINE ST"]},
             {2, ["4TH AVE", "PINE ST"]},
             {7, ["3RD AVE", "PINE ST"]}
           ]
  end

  test "reads the position in microdegrees" do
    %{nodes: [first | _rest]} = run(false)
    assert {first.lat_microdegrees, first.lon_microdegrees} == {47_610_700, -122_337_100}
  end

  test "counts what became of each way and node" do
    %{counts: counts} = run(false)

    assert counts == %{
             ways_read: 10,
             ways_wrong_class: 2,
             ways_unnamed: 1,
             ways_unsupported_name: 1,
             ways_kept: 6,
             road_nodes: 8,
             shared_nodes: 4,
             crowded_nodes: 0,
             outside_nodes: 1,
             malformed_lines: 0
           }
  end

  test "includes the nodes of service roads when they are asked for" do
    %{nodes: nodes, counts: counts} = run(true)

    assert Enum.map(nodes, & &1.id) == [1, 2, 7, 8]
    assert Enum.find(nodes, &(&1.id == 1)).keys == ["3RD AVE", "PARKING AISLE", "PINE ST"]
    assert counts.ways_kept == 7
    assert counts.ways_wrong_class == 1
  end

  test "treats two ways of one street as no crossing" do
    lines = fn ->
      [
        "n1 T x-122.3 y47.6",
        "w1 Thighway=residential,name=Pine%20%St Nn1",
        "w2 Thighway=residential,name=Pine%20%Street Nn1"
      ]
    end

    assert %{nodes: [], counts: %{shared_nodes: 0}} = run(false, lines)
  end

  test "leaves out a node through more than eight keys" do
    ways = for number <- 1..9, do: "w#{number} Thighway=residential,name=Road%20%#{number} Nn1"
    lines = fn -> ["n1 T x-122.3 y47.6" | ways] end

    assert %{nodes: [], counts: %{crowded_nodes: 1, shared_nodes: 0}} = run(false, lines)
  end

  test "counts a malformed line and reads on" do
    lines = fn ->
      ["wx T N", "n1 T x-122.3", "n2 T x-122.3 y47.6", "w1 Tname=A%20%St,highway=residential Nn2"]
    end

    assert %{counts: %{malformed_lines: 1, ways_kept: 1}} = run(false, lines)
  end

  test "reads nothing from an empty export" do
    assert %{nodes: [], counts: %{ways_read: 0}} = run(false, fn -> [] end)
  end
end
