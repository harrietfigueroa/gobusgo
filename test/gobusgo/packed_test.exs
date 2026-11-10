defmodule Gobusgo.PackedTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Gobusgo.Compression
  alias Gobusgo.Packed
  alias Gobusgo.Packed.Kinds
  alias Gobusgo.Packed.Varint
  alias Gobusgo.Test.PackedFixture

  # Each case builds a container, or damages the fixture's bytes, and checks
  # that the decoder returns the rule it breaks as a value.

  defp expectation(overrides \\ %{}) do
    Map.merge(
      %{
        kind: PackedFixture.kind(),
        versions: [PackedFixture.version()],
        section_count: PackedFixture.section_count()
      },
      overrides
    )
  end

  defp fixture_directory, do: PackedFixture.directory()

  defp container(strings, sections) do
    Packed.encode(%{
      kind: PackedFixture.kind(),
      version: PackedFixture.version(),
      record_count: 0,
      strings: strings,
      sections: sections
    })
  end

  test "the fixture's expanded bytes are what the encoder writes" do
    assert File.read!(Path.join(fixture_directory(), "fixture.bin")) == PackedFixture.encode()
  end

  test "the fixture's gzip stream expands to the fixture's bytes" do
    stream = File.read!(Path.join(fixture_directory(), "fixture.bin.gz"))

    assert Packed.expand(stream, Compression.content_bytes_max()) ==
             {:ok, PackedFixture.encode()}
  end

  test "the fixture's expected.json is what the fixture's records write" do
    expected = File.read!(Path.join(fixture_directory(), "expected.json"))
    assert expected == Gobusgo.CanonicalJson.encode(PackedFixture.expected()) <> "\n"
  end

  test "the fixture decodes to its header, strings, and sections" do
    {:ok, decoded} = Packed.decode(PackedFixture.encode(), expectation())

    assert %{kind: 0, version: 1, record_count: 5} = decoded

    assert Tuple.to_list(decoded.strings) ==
             ["Pike Place Market — 1st Ave", "Bothell–Everett", "", "Café Münster 東京"]

    assert length(decoded.sections) == PackedFixture.section_count()
  end

  test "an empty container decodes to no strings and no sections" do
    {:ok, decoded} = Packed.decode(container([], []), expectation(%{section_count: 0}))
    assert decoded.strings == {}
    assert decoded.sections == []
  end

  test "the kind table is the one in kinds.json" do
    json = File.read!(Path.join(fixture_directory(), "../kinds.json")) |> JSON.decode!()

    table =
      for kind <- Kinds.all(),
          do: %{"number" => kind.number, "name" => kind.name, "prefix" => kind.prefix}

    assert json == table
  end

  describe "decode refuses" do
    test "a file with another magic" do
      <<_magic::binary-size(4), rest::binary>> = PackedFixture.encode()
      assert Packed.decode("GBPX" <> rest, expectation()) == {:error, :bad_magic}
    end

    test "a file shorter than its header" do
      assert Packed.decode("GBPK", expectation()) == {:error, :truncated}
      assert Packed.decode("", expectation()) == {:error, :truncated}
    end

    test "a kind not in the table" do
      <<head::binary-size(6), _kind::little-16, rest::binary>> = PackedFixture.encode()

      assert Packed.decode(<<head::binary, 99::little-16, rest::binary>>, expectation()) ==
               {:error, :unknown_kind}
    end

    test "another kind than the reader's" do
      assert Packed.decode(PackedFixture.encode(), expectation(%{kind: 1})) ==
               {:error, :kind_mismatch}
    end

    test "a version the reader does not know" do
      assert Packed.decode(PackedFixture.encode(), expectation(%{versions: [2, 3]})) ==
               {:error, :unsupported_version}
    end

    test "a reserved field that is not zero" do
      <<head::binary-size(12), _reserved::little-32, rest::binary>> = PackedFixture.encode()

      assert Packed.decode(<<head::binary, 1::little-32, rest::binary>>, expectation()) ==
               {:error, :reserved_not_zero}
    end

    test "a file cut inside a section" do
      expanded = PackedFixture.encode()
      cut = binary_part(expanded, 0, byte_size(expanded) - 1)
      assert Packed.decode(cut, expectation()) == {:error, :truncated}
    end

    test "bytes after the last section" do
      assert Packed.decode(PackedFixture.encode() <> <<0>>, expectation()) ==
               {:error, :trailing_bytes}
    end

    test "another section count than the kind declares" do
      assert Packed.decode(PackedFixture.encode(), expectation(%{section_count: 5})) ==
               {:error, :section_count}

      assert Packed.decode(PackedFixture.encode(), expectation(%{section_count: 7})) ==
               {:error, :section_count}
    end

    test "a file with no string table" do
      <<header::binary-size(16), _rest::binary>> = PackedFixture.encode()
      assert Packed.decode(header, expectation()) == {:error, :section_count}
    end

    test "a string table entry that is not UTF-8" do
      table = <<1::little-32, 2, 0xC3, 0x28>>
      expanded = container([], []) |> replace_table(table)
      assert Packed.decode(expanded, expectation(%{section_count: 0})) == {:error, :bad_utf8}
    end

    test "a string table with an over-long length varint" do
      table = <<1::little-32, 0x80, 0x80, 0x80, 0x80, 0x80, 0x01>>
      expanded = container([], []) |> replace_table(table)
      assert Packed.decode(expanded, expectation(%{section_count: 0})) == {:error, :bad_varint}
    end

    test "a string table with bytes after its last entry" do
      table = <<1::little-32, 1, ?a, 0>>
      expanded = container([], []) |> replace_table(table)

      assert Packed.decode(expanded, expectation(%{section_count: 0})) ==
               {:error, :bad_string_table}
    end

    test "a string table that claims more entries than it holds" do
      table = <<3::little-32, 1, ?a>>
      expanded = container([], []) |> replace_table(table)
      assert Packed.decode(expanded, expectation(%{section_count: 0})) == {:error, :truncated}
    end
  end

  # The header with `table` as the string table section.
  defp replace_table(<<header::binary-size(16), _table::binary>>, table) do
    <<header::binary, byte_size(table)::little-32, table::binary>>
  end

  test "the encoder refuses a kind that is not in the table" do
    assert_raise Gobusgo.Assert.AssertionError, fn ->
      Packed.encode(%{kind: 99, version: 1, record_count: 0, strings: [], sections: []})
    end
  end

  test "the encoder refuses a repeated string table entry" do
    assert_raise Gobusgo.Assert.AssertionError, fn -> container(["a", "a"], []) end
  end

  describe "stored" do
    test "the hash is that of the gzip stream the writer stores" do
      expanded = PackedFixture.encode()
      stored = Packed.stored(expanded)

      assert stored.content == expanded
      assert stored.stream == Compression.compress(expanded)
      assert stored.byte_size == byte_size(stored.stream)
      assert stored.sha256 == :crypto.hash(:sha256, stored.stream) |> Base.encode16(case: :lower)
    end

    test "the destination names the kind's prefix and the hash" do
      stored = Packed.stored(PackedFixture.encode())

      assert Packed.destination(%{directory: "d/dt=2026-11-10", kind: 1, stored: stored}) ==
               "d/dt=2026-11-10/trip-paths-#{stored.sha256}.bin.gz"
    end

    test "the manifest entry holds the path, the stream's size, and its hash" do
      stored = Packed.stored(PackedFixture.encode())

      assert Packed.file_entry("/d/x.bin.gz", stored) ==
               %{
                 "path" => "/d/x.bin.gz",
                 "byteSize" => stored.byte_size,
                 "sha256" => stored.sha256
               }
    end
  end

  describe "expand" do
    test "refuses a stream that expands past the bound" do
      stream = Compression.compress(PackedFixture.encode())
      assert Packed.expand(stream, 16) == {:error, :too_large}
    end

    test "refuses a stream that is not gzip" do
      assert Packed.expand("not gzip", 1_000) == {:error, :corrupt}
    end
  end

  test "a varint of the largest value is five bytes" do
    assert byte_size(Varint.encode(Varint.value_max())) == 5
  end
end
