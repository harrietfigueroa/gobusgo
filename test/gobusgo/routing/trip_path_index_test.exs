defmodule Gobusgo.Routing.TripPathIndexTest do
  # Builds indexes from the fixture's two hand-written shard records and
  # damages the bytes one rule at a time to check each refusal as a value.
  use ExUnit.Case, async: true

  alias Gobusgo.Compression
  alias Gobusgo.Packed
  alias Gobusgo.Routing.TripPathIndex
  alias Gobusgo.Test.TripPathShardFixture

  @fixture_directory TripPathShardFixture.directory()

  defp fixture_bytes(name), do: @fixture_directory |> Path.join(name) |> File.read!()

  defp section(content, index) do
    {:ok, decoded} = Packed.decode(content, %{kind: 2, versions: [1], section_count: 2})
    Enum.at(decoded.sections, index)
  end

  defp replace_section(content, index, section) do
    {:ok, decoded} = Packed.decode(content, %{kind: 2, versions: [1], section_count: 2})

    Packed.encode(%{
      kind: 2,
      version: 1,
      record_count: decoded.record_count,
      strings: Tuple.to_list(decoded.strings),
      sections: List.replace_at(decoded.sections, index, section)
    })
  end

  test "the fixture's expanded bytes are what the builder writes" do
    assert fixture_bytes("index.bin") == TripPathShardFixture.index_content()
  end

  test "the fixture's gzip stream holds the same content" do
    {:ok, content} = Packed.expand(fixture_bytes("index.bin.gz"), Compression.content_bytes_max())

    assert content == fixture_bytes("index.bin")
  end

  test "decodes the records in route identifier order" do
    {:ok, records} = TripPathIndex.decode(fixture_bytes("index.bin"))

    assert records == Enum.sort_by(TripPathShardFixture.index_shards(), & &1.route_id)
  end

  test "writes the same bytes whatever the order of the shards" do
    shards = TripPathShardFixture.index_shards()

    assert TripPathIndex.build(Enum.reverse(shards)) == TripPathIndex.build(shards)
  end

  test "keeps a byte size of the largest u32" do
    {:ok, records} = TripPathIndex.decode(fixture_bytes("index.bin"))

    assert Enum.max(Enum.map(records, & &1.byte_size)) == 4_294_967_295
  end

  test "refuses two shards of one route" do
    [shard | _rest] = TripPathShardFixture.index_shards()

    assert_raise Gobusgo.Assert.AssertionError, fn ->
      TripPathIndex.build([shard, shard])
    end
  end

  test "refuses a shard file as another kind" do
    assert {:error, :kind_mismatch} = TripPathIndex.decode(fixture_bytes("shard.bin"))
  end

  test "refuses a hash section of another length than 32 bytes a record" do
    content = fixture_bytes("index.bin")
    hashes = section(content, 1)
    damaged = replace_section(content, 1, binary_part(hashes, 0, byte_size(hashes) - 1))

    assert {:error, :bad_section_size} = TripPathIndex.decode(damaged)
  end

  test "refuses a column section of another length than three values a record" do
    content = fixture_bytes("index.bin")
    columns = section(content, 0)
    damaged = replace_section(content, 0, binary_part(columns, 0, byte_size(columns) - 4))

    assert {:error, :bad_section_size} = TripPathIndex.decode(damaged)
  end

  test "refuses a record that names a string the table lacks" do
    content = fixture_bytes("index.bin")
    <<_route::binary-size(4), rest::binary>> = section(content, 0)
    damaged = replace_section(content, 0, <<99::little-32, rest::binary>>)

    assert {:error, :bad_index} = TripPathIndex.decode(damaged)
  end
end
