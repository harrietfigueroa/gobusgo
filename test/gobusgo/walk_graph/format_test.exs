defmodule Gobusgo.WalkGraph.FormatTest do
  # Checks the walk graph shard and index kinds against the shared fixtures
  # under test/fixtures/walk_graph/v1/, which the JavaScript reader decodes
  # too, and against the rules the kinds refuse a file for.
  use ExUnit.Case, async: true

  alias Gobusgo.Packed
  alias Gobusgo.Packed.Columns
  alias Gobusgo.Packed.Positions
  alias Gobusgo.Test.WalkGraphFixture
  alias Gobusgo.WalkGraph.Format

  @directory WalkGraphFixture.directory()
  @shard_expectation %{kind: 8, versions: [1], section_count: 3}
  @index_expectation %{kind: 9, versions: [1], section_count: 3}
  @sizes %{lat: 1_000, lon: 1_500}

  defp fixture(name), do: File.read!(Path.join(@directory, name))

  defp with_section(binary, expectation, index, replacement) do
    {:ok, container} = Packed.decode(binary, expectation)

    Packed.encode(%{
      kind: container.kind,
      version: container.version,
      record_count: container.record_count,
      strings: Tuple.to_list(container.strings),
      sections: List.replace_at(container.sections, index, replacement)
    })
  end

  defp shard_with(index, replacement),
    do: with_section(fixture("shard-west.bin"), @shard_expectation, index, replacement)

  describe "the shard" do
    test "encodes the fixture pieces to the bytes of shard-west.bin and shard-east.bin" do
      assert WalkGraphFixture.encode_shard(:west) == fixture("shard-west.bin")
      assert WalkGraphFixture.encode_shard(:east) == fixture("shard-east.bin")
    end

    test "the gzip files expand to the bytes of the expanded files" do
      for name <- ["shard-west", "shard-east", "index"] do
        kind = if name == "index", do: :index, else: :shard

        assert Packed.expand(fixture(name <> ".bin.gz"), Format.expanded_bytes_max(kind)) ==
                 {:ok, fixture(name <> ".bin")}
      end
    end

    test "decodes the pieces the fixture was written from" do
      assert Format.decode_shard(fixture("shard-west.bin")) ==
               {:ok, %{pieces: WalkGraphFixture.pieces(:west)}}
    end

    test "refuses the index read as a shard" do
      assert Format.decode_shard(fixture("index.bin")) == {:error, :kind_mismatch}
    end

    test "refuses a class past the last" do
      assert Format.decode_shard(shard_with(0, Columns.encode(:u8, [5, 0, 0, 0, 0, 0, 0, 0, 0]))) ==
               {:error, :bad_class}
    end

    test "refuses a piece of one position" do
      counts = Columns.encode(:u16, [1, 2, 2, 2, 3, 3, 2, 3, 2])
      assert Format.decode_shard(shard_with(1, counts)) == {:error, :bad_counts}
    end

    test "refuses counts the path does not hold" do
      counts = Columns.encode(:u16, [3, 2, 2, 2, 3, 3, 2, 3, 2])
      assert Format.decode_shard(shard_with(1, counts)) == {:error, :count_mismatch}
    end

    test "refuses bytes after the path" do
      points = for piece <- WalkGraphFixture.pieces(:west), point <- piece.points, do: point
      padded = Positions.encode_path(points) <> <<0>>
      assert Format.decode_shard(shard_with(2, padded)) == {:error, :bad_section_size}
    end

    test "refuses a column of another length" do
      assert Format.decode_shard(shard_with(0, <<0>>)) == {:error, :bad_section_size}
    end

    test "asserts a piece of one position when encoding" do
      assert_raise Gobusgo.Assert.AssertionError, ~r/2 to 65535 positions/, fn ->
        Format.encode_shard([%{class: 0, points: [{1, 1}]}])
      end
    end

    test "asserts a class past the last when encoding" do
      assert_raise Gobusgo.Assert.AssertionError, ~r/class is 0 to 4/, fn ->
        Format.encode_shard([%{class: 5, points: [{1, 1}, {2, 2}]}])
      end
    end

    test "asserts a shard past the size a reader accepts" do
      assert_raise Gobusgo.Assert.AssertionError, ~r/must expand to at most/, fn ->
        Format.assert_expanded_size(
          :shard,
          :binary.copy(<<0>>, Format.expanded_bytes_max(:shard) + 1)
        )
      end
    end
  end

  describe "order/2" do
    test "orders pieces by the Morton code of their first position inside the tile" do
      far =
        {4,
         <<4_761_900::signed-32, -12_233_000::signed-32, 4_761_950::signed-32,
           -12_233_000::signed-32>>}

      near =
        {4,
         <<4_761_001::signed-32, -12_233_999::signed-32, 4_761_002::signed-32,
           -12_233_999::signed-32>>}

      ordered = Format.order([far, near], %{tile: {4_761, -8_156}, tile_sizes: @sizes})

      assert Enum.map(ordered, &hd(&1.points)) == [
               {4_761_001, -12_233_999},
               {4_761_900, -12_233_000}
             ]
    end

    test "asserts a piece that starts outside its tile" do
      outside = {0, <<0::signed-32, 0::signed-32, 1::signed-32, 1::signed-32>>}

      assert_raise Gobusgo.Assert.AssertionError, ~r/starts inside its tile/, fn ->
        Format.order([outside], %{tile: {4_761, -8_156}, tile_sizes: @sizes})
      end
    end
  end

  describe "the index" do
    test "encodes the fixture tiles to the bytes of index.bin" do
      assert WalkGraphFixture.encode_index() == fixture("index.bin")
    end

    test "decodes the build and every tile of its runs" do
      assert Format.decode_index(fixture("index.bin")) ==
               {:ok, %{build_id: WalkGraphFixture.build_id(), tiles: WalkGraphFixture.tiles()}}
    end

    test "refuses the shard read as an index" do
      assert Format.decode_index(fixture("shard-west.bin")) == {:error, :kind_mismatch}
    end

    test "refuses a build identifier that is not 16 lower case hexadecimal digits" do
      {:ok, container} = Packed.decode(fixture("index.bin"), @index_expectation)

      bad =
        Packed.encode(%{
          kind: container.kind,
          version: container.version,
          record_count: container.record_count,
          strings: ["0123456789ABCDEF"],
          sections: container.sections
        })

      assert Format.decode_index(bad) == {:error, :bad_build_id}
    end

    test "refuses a run of no tiles" do
      zero =
        with_section(fixture("index.bin"), @index_expectation, 2, Columns.encode(:u16, [0, 2, 1]))

      assert Format.decode_index(zero) == {:error, :bad_runs}
    end

    test "asserts tiles out of order when encoding" do
      assert_raise Gobusgo.Assert.AssertionError, ~r/distinct and in order/, fn ->
        Format.encode_index(%{build_id: "0123456789abcdef", tiles: [{2, 2}, {1, 1}]})
      end
    end

    test "asserts a malformed build identifier when encoding" do
      assert_raise Gobusgo.Assert.AssertionError, ~r/build identifier/, fn ->
        Format.encode_index(%{build_id: "nope", tiles: [{1, 1}]})
      end
    end

    test "cuts a run of more tiles than a length column holds" do
      tiles = for column <- 1..70_000, do: {0, column}
      index = %{build_id: "0123456789abcdef", tiles: tiles}
      assert Format.decode_index(Format.encode_index(index)) == {:ok, index}
    end
  end

  test "names a shard's file from the build and the tile" do
    assert Format.shard_file_name(%{build_id: "0123456789abcdef", tile: {4_761, -8_156}}) ==
             "walk-graph-0123456789abcdef-4761_-8156.bin.gz"
  end

  test "describes a shard and an index for the decode task" do
    {:ok, shard} = Packed.decode(fixture("shard-east.bin"), @shard_expectation)
    assert %{"pieceCount" => 1, "pieces" => [%{"class" => 4}]} = Format.inspect(shard)

    {:ok, index} = Packed.decode(fixture("index.bin"), @index_expectation)
    assert %{"buildId" => "0123456789abcdef", "tileCount" => 5} = Format.inspect(index)
  end
end
