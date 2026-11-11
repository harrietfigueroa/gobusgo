defmodule Gobusgo.Addresses.FormatTest do
  # Checks the address shard and index kinds against the shared fixtures
  # under test/fixtures/addresses/v1/, which the JavaScript reader decodes
  # too, and against the rules the kinds refuse a file for.
  use ExUnit.Case, async: true

  alias Gobusgo.Addresses.Format
  alias Gobusgo.Addresses.Rows
  alias Gobusgo.Packed
  alias Gobusgo.Packed.Columns
  alias Gobusgo.Packed.Positions
  alias Gobusgo.Packed.Varint
  alias Gobusgo.Test.AddressFixture

  @directory AddressFixture.directory()
  @shard_expectation %{kind: 3, versions: [1], section_count: 8}
  @index_expectation %{kind: 4, versions: [1], section_count: 4}

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

  defp first_street, do: hd(AddressFixture.streets())

  describe "the shard" do
    test "encodes the fixture streets to the bytes of shard.bin" do
      assert AddressFixture.encode_shard() == fixture("shard.bin")
    end

    test "shard.bin.gz expands to shard.bin" do
      stream = fixture("shard.bin.gz")

      assert Packed.expand(stream, Format.expanded_bytes_max(:shard)) ==
               {:ok, fixture("shard.bin")}
    end

    test "decodes the streets the fixture was written from" do
      assert {:ok, %{streets: streets}} = Format.decode_shard(fixture("shard.bin"))
      assert streets == Enum.map(AddressFixture.streets(), &Map.delete(&1, :name_key))
    end

    test "decodes the addresses of a street with a letter suffix and a repeated number" do
      assert {:ok, %{streets: [street | _rest]}} = Format.decode_shard(fixture("shard.bin"))

      assert [{920, ""}, {920, "A"}, {920, "B"}, {1204, ""}] ==
               for(address <- Rows.unpack(street.rows), do: {address.number, address.suffix})
    end

    test "decodes a multibyte city, a negative longitude, and the corners of the globe" do
      assert {:ok, %{streets: streets}} = Format.decode_shard(fixture("shard.bin"))
      redmond = Enum.find(streets, &(&1.city == "RÉDMOND"))
      assert Enum.all?(Rows.unpack(redmond.rows), &(&1.lon_microdegrees < 0))

      pole = Enum.find(streets, &(&1.street.name == "POLE"))

      assert [{90_000_000, 180_000_000}, {-90_000_000, -180_000_000}] ==
               for(
                 address <- Rows.unpack(pole.rows),
                 do: {address.lat_microdegrees, address.lon_microdegrees}
               )
    end

    test "stores a string two streets share once" do
      {:ok, %{strings: strings}} = Packed.decode(fixture("shard.bin"), @shard_expectation)
      assert Enum.count(Tuple.to_list(strings), &(&1 == "MAIN")) == 1
      assert Enum.count(Tuple.to_list(strings), &(&1 == "SEATTLE")) == 1
    end

    test "numbers each string by first use, so one input gives one table" do
      {:ok, %{strings: strings}} = Packed.decode(fixture("shard.bin"), @shard_expectation)
      assert strings |> Tuple.to_list() |> Enum.take(5) == ["12TH", "", "AVE", "S", "SEATTLE"]
    end

    test "refuses another version" do
      <<magic::binary-size(4), _version::little-16, rest::binary>> = fixture("shard.bin")

      assert Format.decode_shard(<<magic::binary, 2::little-16, rest::binary>>) ==
               {:error, :unsupported_version}
    end

    test "refuses the index's kind" do
      assert Format.decode_shard(fixture("index.bin")) == {:error, :kind_mismatch}
    end

    test "refuses another section count" do
      assert Format.decode_shard(fixture("shard.bin") <> <<0, 0, 0, 0>>) ==
               {:error, :section_count}
    end

    test "refuses a name index past the string table" do
      names = Columns.encode(:u32, [0, 1, 2, 3, 999])
      assert Format.decode_shard(shard_with(0, names)) == {:error, :bad_string_index}
    end

    test "refuses a column that is not one value a street" do
      assert Format.decode_shard(shard_with(1, <<0, 0, 0, 0>>)) == {:error, :bad_section_size}
    end

    test "refuses numbers that run past their section" do
      assert Format.decode_shard(shard_with(5, <<200, 1>>)) == {:error, :bad_numbers}
    end

    test "refuses bytes left over after the numbers" do
      {:ok, container} = Packed.decode(fixture("shard.bin"), @shard_expectation)
      numbers = Enum.at(container.sections, 5)
      assert Format.decode_shard(shard_with(5, numbers <> <<0>>)) == {:error, :bad_numbers}
    end

    test "refuses a house number past 32 bits" do
      street = fn count, differences ->
        [Varint.encode(count) | Enum.map(differences, &Varint.encode/1)]
      end

      numbers =
        IO.iodata_to_binary([
          street.(4, [Varint.value_max(), 1, 0, 0]),
          street.(2, [0, 0]),
          street.(3, [0, 0, 0]),
          street.(2, [0, 0]),
          street.(1, [0])
        ])

      assert Format.decode_shard(shard_with(5, numbers)) == {:error, :bad_numbers}
    end

    test "the readers' expanded sizes are the ones the browser's decoder repeats" do
      source = File.read!("assets/js/address_file.js")

      for {name, kind} <- [{"SHARD", :shard}, {"INDEX", :index}] do
        [_match, mebibytes] = Regex.run(~r/#{name}_EXPANDED_MEBIBYTES_MAX = (\d+)/, source)
        assert String.to_integer(mebibytes) * 1_048_576 == Format.expanded_bytes_max(kind)
      end
    end

    test "refuses a suffix that is not a letter" do
      {:ok, container} = Packed.decode(fixture("shard.bin"), @shard_expectation)
      suffixes = container.sections |> Enum.at(6) |> binary_part(1, 11)
      assert Format.decode_shard(shard_with(6, <<?1>> <> suffixes)) == {:error, :bad_suffix}
    end

    test "refuses a suffix column of another length" do
      assert Format.decode_shard(shard_with(6, <<0>>)) == {:error, :bad_section_size}
    end

    test "refuses a path of another length than the street's addresses" do
      one_point = Positions.encode_path([{1, 1}])
      {:ok, container} = Packed.decode(fixture("shard.bin"), @shard_expectation)
      positions = Enum.at(container.sections, 7)

      assert Format.decode_shard(shard_with(7, one_point <> positions)) ==
               {:error, :count_mismatch}
    end

    test "refuses a position past the globe" do
      path = Varint.encode(4) <> Varint.encode(Varint.zigzag(2_147_483_647)) <> Varint.encode(0)

      assert Format.decode_shard(shard_with(7, path <> :binary.copy(<<0>>, 8))) ==
               {:error, :bad_position}
    end

    test "asserts a street holds an address" do
      street = %{first_street() | rows: <<>>}

      assert_raise Gobusgo.Assert.AssertionError, ~r/at least one address/, fn ->
        Format.encode_shard([street])
      end
    end

    test "asserts the numbers of a street are in order" do
      rows =
        Rows.pack(%{number: 5, suffix: "", lat_microdegrees: 1, lon_microdegrees: 1}) <>
          Rows.pack(%{number: 4, suffix: "", lat_microdegrees: 1, lon_microdegrees: 1})

      assert_raise Gobusgo.Assert.AssertionError, ~r/in order/, fn ->
        Format.encode_shard([%{first_street() | rows: rows}])
      end
    end

    test "the size lower bound is at most the size of the fixture shard and of one address" do
      assert Format.shard_bytes_min(AddressFixture.streets()) <= byte_size(fixture("shard.bin"))
      assert Format.shard_bytes_min([first_street()]) == 16
    end

    test "asserts the expanded size of a shard within what a reader accepts" do
      at_bound = :binary.copy(<<0>>, Format.expanded_bytes_max(:shard))
      assert Format.assert_expanded_size(:shard, at_bound) == at_bound

      assert_raise Gobusgo.Assert.AssertionError, ~r/shard must expand to at most/, fn ->
        Format.assert_expanded_size(:shard, at_bound <> <<0>>)
      end
    end

    test "inspect describes the container by its streets" do
      {:ok, container} = Packed.decode(fixture("shard.bin"), @shard_expectation)
      description = Format.inspect(container)
      assert description["streetCount"] == 5
      assert description["addressCount"] == 12
      assert hd(description["streets"])["name"] == "12TH"
    end
  end

  describe "the index" do
    test "encodes the fixture entries to the bytes of index.bin" do
      assert AddressFixture.encode_index() == fixture("index.bin")
    end

    test "index.bin.gz expands to index.bin" do
      stream = fixture("index.bin.gz")

      assert Packed.expand(stream, Format.expanded_bytes_max(:index)) ==
               {:ok, fixture("index.bin")}
    end

    test "decodes the entries the fixture was written from" do
      assert Format.decode_index(fixture("index.bin")) ==
               {:ok, %{entries: AddressFixture.index_entries()}}
    end

    test "refuses another version" do
      <<magic::binary-size(4), _version::little-16, rest::binary>> = fixture("index.bin")

      assert Format.decode_index(<<magic::binary, 2::little-16, rest::binary>>) ==
               {:error, :unsupported_version}
    end

    test "refuses the shard's kind" do
      assert Format.decode_index(fixture("shard.bin")) == {:error, :kind_mismatch}
    end

    test "refuses a prefix index past the string table" do
      assert Format.decode_index(index_with(0, Columns.encode(:u32, [0, 1, 2, 999]))) ==
               {:error, :bad_string_index}
    end

    test "refuses digests of another length" do
      assert Format.decode_index(index_with(3, <<0::256>>)) == {:error, :bad_section_size}
    end

    test "asserts a digest is 64 lower case hexadecimal digits" do
      entry = %{hd(AddressFixture.index_entries()) | sha256: "ABC"}

      assert_raise Gobusgo.Assert.AssertionError, ~r/hexadecimal/, fn ->
        Format.encode_index([entry])
      end
    end

    test "inspect describes the container by its shards" do
      {:ok, container} = Packed.decode(fixture("index.bin"), @index_expectation)
      description = Format.inspect(container)
      assert description["shardCount"] == 4
      assert hd(description["shards"])["prefix"] == ""
    end
  end

  test "inspect refuses a kind that is not an address kind" do
    assert Format.inspect(%{kind: 5, version: 1, record_count: 0, strings: {}, sections: []}) ==
             %{"refused" => "not_address_v1"}
  end
end
