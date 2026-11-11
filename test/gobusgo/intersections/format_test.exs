defmodule Gobusgo.Intersections.FormatTest do
  # Checks the intersection shard and index kinds against the shared fixtures
  # under test/fixtures/intersections/v1/, which the JavaScript reader decodes
  # too, and against the rules the kinds refuse a file for.
  use ExUnit.Case, async: true

  alias Gobusgo.Intersections.Format
  alias Gobusgo.Packed
  alias Gobusgo.Packed.Columns
  alias Gobusgo.Packed.Positions
  alias Gobusgo.Packed.Varint
  alias Gobusgo.Test.IntersectionFixture

  @directory IntersectionFixture.directory()
  @shard_expectation %{kind: 6, versions: [1], section_count: 4}
  @index_expectation %{kind: 7, versions: [1], section_count: 3}

  defp fixture(name), do: File.read!(Path.join(@directory, name))

  # Replaces one section after the string table, counted from 0, in a container.
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
    do: with_section(fixture("shard.bin"), @shard_expectation, index, replacement)

  defp index_with(index, replacement),
    do: with_section(fixture("index.bin"), @index_expectation, index, replacement)

  describe "the shard" do
    test "encodes the fixture streets to the bytes of shard.bin" do
      assert IntersectionFixture.encode_shard() == fixture("shard.bin")
    end

    test "shard.bin.gz expands to shard.bin" do
      assert Packed.expand(fixture("shard.bin.gz"), Format.expanded_bytes_max(:shard)) ==
               {:ok, fixture("shard.bin")}
    end

    test "decodes the streets the fixture was written from" do
      assert {:ok, %{streets: streets}} = Format.decode_shard(fixture("shard.bin"))
      assert streets == Enum.map(IntersectionFixture.streets(), &Map.delete(&1, :name_key))
    end

    test "decodes the corners of the globe and a multibyte street" do
      assert {:ok, %{streets: streets}} = Format.decode_shard(fixture("shard.bin"))
      pole = Enum.find(streets, &(&1.key == "POLE"))

      assert [{"ÉQUATEUR", 90_000_000, 180_000_000}, {"MERIDIAN", -90_000_000, -180_000_000}] ==
               for(c <- pole.crossings, do: {c.other, c.lat_microdegrees, c.lon_microdegrees})
    end

    test "stores a string two streets share once" do
      {:ok, container} = Packed.decode(fixture("shard.bin"), @shard_expectation)
      strings = Tuple.to_list(container.strings)
      assert Enum.count(strings, &(&1 == "PIKE ST")) == 1
    end

    test "refuses the index kind" do
      assert Format.decode_shard(fixture("index.bin")) == {:error, :kind_mismatch}
    end

    test "refuses another version" do
      <<head::binary-size(4), _version::little-16, rest::binary>> = fixture("shard.bin")

      assert Format.decode_shard(<<head::binary, 2::little-16, rest::binary>>) ==
               {:error, :unsupported_version}
    end

    test "refuses a string index past the table" do
      assert Format.decode_shard(shard_with(0, Columns.encode(:u32, List.duplicate(999, 6)))) ==
               {:error, :bad_string_index}
    end

    test "refuses a crossing count of zero" do
      counts = Columns.encode(:u32, [0, 2, 2, 2, 2, 1])
      assert Format.decode_shard(shard_with(1, counts)) == {:error, :bad_counts}
    end

    test "refuses a column of another length" do
      assert Format.decode_shard(shard_with(1, Columns.encode(:u32, [2, 2]))) ==
               {:error, :bad_section_size}
    end

    test "refuses a path of another length than its street's crossings" do
      counts = Columns.encode(:u32, [1, 3, 2, 2, 2, 1])

      assert {:error, reason} = Format.decode_shard(shard_with(1, counts))
      assert reason in [:bad_section_size, :count_mismatch]
    end

    test "refuses positions past the globe" do
      points =
        IO.iodata_to_binary([Varint.encode(1), Varint.encode(Varint.zigzag(91_000_000)), 0])

      assert {:error, :bad_position} = Format.decode_shard(shard_with(3, points))
    end

    test "refuses positions followed by more bytes" do
      positions = Positions.encode_path([{0, 0}])
      {:ok, container} = Packed.decode(fixture("shard.bin"), @shard_expectation)

      sections =
        List.replace_at(container.sections, 3, List.last(container.sections) <> positions)

      broken = %{container | sections: sections}

      encoded =
        Packed.encode(%{
          kind: 6,
          version: 1,
          record_count: broken.record_count,
          strings: Tuple.to_list(broken.strings),
          sections: broken.sections
        })

      assert {:error, :bad_section_size} = Format.decode_shard(encoded)
    end

    test "asserts a street holds at least one crossing" do
      assert_raise Gobusgo.Assert.AssertionError, fn ->
        Format.encode_shard([%{key: "A ST", name_key: "A", crossings: []}])
      end
    end

    test "asserts the expanded size a reader accepts" do
      assert_raise Gobusgo.Assert.AssertionError, fn ->
        Format.assert_expanded_size(:shard, :binary.copy(<<0>>, 1_048_577))
      end
    end
  end

  describe "shard_bytes_min/1" do
    test "never exceeds the encoded size of a group" do
      streets = IntersectionFixture.streets()
      assert Format.shard_bytes_min(streets) <= byte_size(Format.encode_shard(streets))
    end
  end

  describe "the index" do
    test "encodes the fixture entries to the bytes of index.bin" do
      assert IntersectionFixture.encode_index() == fixture("index.bin")
    end

    test "index.bin.gz expands to index.bin" do
      assert Packed.expand(fixture("index.bin.gz"), Format.expanded_bytes_max(:index)) ==
               {:ok, fixture("index.bin")}
    end

    test "decodes the entries the fixture was written from" do
      assert {:ok, %{entries: entries}} = Format.decode_index(fixture("index.bin"))
      assert entries == IntersectionFixture.index_entries()
    end

    test "refuses the shard kind" do
      assert Format.decode_index(fixture("shard.bin")) == {:error, :kind_mismatch}
    end

    test "refuses a digest section of another length" do
      assert Format.decode_index(index_with(2, <<1, 2, 3>>)) == {:error, :bad_section_size}
    end

    test "asserts a digest of 64 hexadecimal digits" do
      assert_raise Gobusgo.Assert.AssertionError, fn ->
        Format.encode_index([%{prefix: "", byte_size: 1, sha256: "abc"}])
      end
    end
  end

  describe "inspect/1" do
    test "describes a shard and an index as JSON-encodable maps" do
      {:ok, shard} = Packed.decode(fixture("shard.bin"), @shard_expectation)
      {:ok, index} = Packed.decode(fixture("index.bin"), @index_expectation)

      assert %{"streetCount" => 6, "crossingCount" => 11} = Format.inspect(shard)
      assert %{"shardCount" => 4} = Format.inspect(index)
      assert %{"refused" => _} = Format.inspect(%{kind: 3, version: 1})
    end
  end
end
