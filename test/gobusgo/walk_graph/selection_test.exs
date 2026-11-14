defmodule Gobusgo.WalkGraph.SelectionTest do
  # Reads a hand-written OPL export, nodes first as osmium writes them, and
  # checks the pieces it cuts by tile and the counts of what became of each
  # way. Two walkable ways meet at one node, a motorway and a private
  # driveway are left out, and a way lists a node the export lacks.
  use ExUnit.Case, async: true

  alias Gobusgo.WalkGraph.Selection

  @lines [
    "n1 T x-122.3400 y47.6100",
    "n2 T x-122.3390 y47.6100",
    "n3 T x-122.3380 y47.6100",
    "n4 T x-122.3390 y47.6110",
    "n5 T x-122.3370 y47.6100",
    "n6 T x-122.3370 y47.6110",
    "n7 T x-122.3400 y47.6110",
    "w10 Thighway=residential,name=Pine%20%Street Nn1,n2,n3",
    "w11 Thighway=footway,footway=sidewalk Nn2,n4",
    "w12 Thighway=motorway Nn5,n6",
    "w13 Thighway=service,access=private Nn1,n7",
    "w14 Thighway=footway Nn4,n99",
    "w15 Thighway=footway Nn1",
    "malformed line"
  ]

  defp run(lines \\ @lines) do
    Selection.run(%{
      lines: fn -> lines end,
      tile_sizes: %{lat: 1_000, lon: 1_500},
      simplify_units: 1.0
    })
  end

  defp points(binary), do: for(<<lat::signed-32, lon::signed-32 <- binary>>, do: {lat, lon})

  test "cuts each walkable way at its junctions into the pieces of its tile" do
    %{tiles: tiles} = run()

    assert Map.keys(tiles) == [{4_761, -8_156}]

    pieces = for {class, binary} <- tiles[{4_761, -8_156}], do: {class, points(binary)}

    assert Enum.sort(pieces) == [
             {1, [{4_761_000, -12_233_900}, {4_761_100, -12_233_900}]},
             {4, [{4_761_000, -12_234_000}, {4_761_000, -12_233_900}]},
             {4, [{4_761_000, -12_233_900}, {4_761_000, -12_233_800}]}
           ]
  end

  test "counts what became of each way and node" do
    %{counts: counts} = run()

    assert counts == %{
             ways_read: 6,
             ways_kept: 4,
             ways_excluded: %{motorway: 1, access_closed: 1},
             ways_missing_nodes: 1,
             nodes: 7,
             junction_nodes: 5,
             pieces: 3,
             points: 6,
             malformed_lines: 0
           }
  end

  test "counts a way that lists a node the export lacks and draws none of it" do
    %{tiles: tiles} = run(["n1 T x-122.3400 y47.6100", "w1 Thighway=footway Nn1,n2"])
    assert tiles == %{}
  end

  test "counts a malformed way line" do
    %{counts: counts} = run(["n1 T x-122.3400 y47.6100", "wx Thighway=footway Nn1,n1"])
    assert counts.malformed_lines == 1
  end

  test "cuts a closed way at its middle into two pieces, none of which starts and ends at one position" do
    lines = [
      "n1 T x-122.3400 y47.6100",
      "n2 T x-122.3390 y47.6100",
      "n3 T x-122.3390 y47.6110",
      "w1 Thighway=footway Nn1,n2,n3,n1"
    ]

    %{counts: counts, tiles: tiles} = run(lines)
    assert counts.pieces == 2
    assert counts.junction_nodes == 1
    pieces = for {0, binary} <- tiles[{4_761, -8_156}], do: points(binary)
    assert Enum.all?(pieces, &(hd(&1) != List.last(&1)))
  end
end
