defmodule Gobusgo.WalkGraph.GeometryTest do
  # Checks the pure cutting of a way: into edges at junctions, edges into
  # pieces at tile edges, and the simplification of an edge's shape.
  use ExUnit.Case, async: true

  alias Gobusgo.WalkGraph.Edges
  alias Gobusgo.WalkGraph.Simplify
  alias Gobusgo.WalkGraph.Tiles

  @sizes %{lat: 1_000, lon: 1_500}

  describe "Edges.cut/1" do
    test "cuts a way at its junctions and keeps the junction in both edges" do
      vertices = [{0, 0, false}, {0, 10, true}, {0, 20, false}, {0, 30, true}, {0, 40, false}]

      assert Edges.cut(vertices) == [
               [{0, 0}, {0, 10}],
               [{0, 10}, {0, 20}, {0, 30}],
               [{0, 30}, {0, 40}]
             ]
    end

    test "ends an edge at the first and last vertex whatever their flag" do
      assert Edges.cut([{0, 0, false}, {0, 5, false}, {0, 10, false}]) == [
               [{0, 0}, {0, 5}, {0, 10}]
             ]
    end

    test "drops a vertex at the position of the one before it, keeping its junction flag" do
      vertices = [{0, 0, false}, {0, 10, false}, {0, 10, true}, {0, 20, false}, {0, 30, false}]

      assert Edges.cut(vertices) == [[{0, 0}, {0, 10}], [{0, 10}, {0, 20}, {0, 30}]]
    end

    test "gives no edge to a way of fewer than two distinct positions" do
      assert Edges.cut([]) == []
      assert Edges.cut([{1, 1, true}]) == []
      assert Edges.cut([{1, 1, true}, {1, 1, true}]) == []
    end

    test "cuts an edge past the position bound into edges that share a position" do
      count = Edges.points_max() + 5
      vertices = for lon <- 1..count, do: {0, lon, false}
      edges = Edges.cut(vertices)

      assert Enum.all?(edges, &(length(&1) <= Edges.points_max()))
      assert edges |> Enum.map(&length/1) |> Enum.sum() == count + length(edges) - 1

      for [left, right] <- Enum.chunk_every(edges, 2, 1, :discard) do
        assert List.last(left) == hd(right)
      end
    end
  end

  describe "Tiles.cut/2" do
    test "keeps a path inside one tile whole" do
      assert Tiles.cut([{10, 10}, {20, 20}, {30, 40}], @sizes) == [
               {{0, 0}, [{10, 10}, {20, 20}, {30, 40}]}
             ]
    end

    test "ends a piece at the first position of the next tile, which the next piece starts from" do
      path = [{10, 1_400}, {10, 1_600}, {10, 1_700}, {10, 3_100}]

      assert Tiles.cut(path, @sizes) == [
               {{0, 0}, [{10, 1_400}, {10, 1_600}]},
               {{0, 1}, [{10, 1_600}, {10, 1_700}, {10, 3_100}]}
             ]
    end

    test "gives a position past the last tile no piece of its own" do
      assert Tiles.cut([{10, 10}, {10, 2_000}], @sizes) == [{{0, 0}, [{10, 10}, {10, 2_000}]}]
    end

    test "numbers a negative position's tile by the floor" do
      assert Tiles.tile_of({-1, -1}, @sizes) == {-1, -1}
      assert Tiles.tile_of({4_761_450, -12_233_600}, @sizes) == {4_761, -8_156}
    end

    test "has no piece for fewer than two positions" do
      assert Tiles.cut([], @sizes) == []
      assert Tiles.cut([{1, 1}], @sizes) == []
    end
  end

  describe "Simplify.run/2" do
    @options %{tolerance: 1.0, units_per_degree: 100_000}

    test "drops positions on a straight line and keeps the ends" do
      line = for lon <- 0..10, do: {4_761_000, lon * 10}
      assert Simplify.run(line, @options) == [{4_761_000, 0}, {4_761_000, 100}]
    end

    test "keeps a corner past the tolerance" do
      line = [{4_761_000, 0}, {4_761_000, 100}, {4_761_100, 100}]
      assert Simplify.run(line, @options) == line
    end

    test "drops a bend within the tolerance" do
      line = [{4_761_000, 0}, {4_761_001, 50}, {4_761_000, 100}]
      assert Simplify.run(line, @options) == [{4_761_000, 0}, {4_761_000, 100}]
    end

    test "leaves a path of two positions alone" do
      assert Simplify.run([{1, 1}, {5, 5}], @options) == [{1, 1}, {5, 5}]
    end

    test "keeps a loop whose ends are one position" do
      loop = [{4_761_000, 0}, {4_761_100, 0}, {4_761_100, 100}, {4_761_000, 0}]
      assert Simplify.run(loop, @options) == loop
    end
  end
end
