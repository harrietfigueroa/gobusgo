defmodule Gobusgo.Test.AddressFixture do
  @moduledoc """
  The records of the shared address fixtures under
  `test/fixtures/addresses/v1/`: `shard.bin`, an address shard as the packed
  container holds it, `index.bin`, an address index, each also as one gzip
  stream (`.bin.gz`), and `expected.json`, what a reader decodes from each.

  The shard holds five streets: one with letter suffixes and a repeated
  number, two of one name in two postal cities, one of them with a multibyte
  city and a negative longitude, a street at the corners of the globe with
  no postal city, and a street of one address with the largest house number
  the build accepts. The index holds shards whose prefixes include the empty
  prefix, a prefix a longer prefix extends, and the own-name mark.
  """

  alias Gobusgo.Addresses.Normalize
  alias Gobusgo.Addresses.Rows
  alias Gobusgo.Addresses.Format

  @directory Path.expand("../fixtures/addresses/v1", __DIR__)

  @streets [
    %{
      pre_direction: "",
      name: "12TH",
      type: "AVE",
      suf_direction: "S",
      city: "SEATTLE",
      addresses: [
        {920, "", 47_590_100, -122_316_200},
        {920, "A", 47_590_150, -122_316_250},
        {920, "B", 47_590_050, -122_316_100},
        {1204, "", 47_589_000, -122_316_900}
      ]
    },
    %{
      pre_direction: "",
      name: "MAIN",
      type: "ST",
      suf_direction: "",
      city: "KENT",
      addresses: [{1, "", 47_380_000, -122_234_000}, {3, "", 47_380_100, -122_234_000}]
    },
    %{
      pre_direction: "",
      name: "MAIN",
      type: "ST",
      suf_direction: "",
      city: "RÉDMOND",
      addresses: [
        {5, "", 47_674_000, -122_121_000},
        {7, "", 47_674_000, -122_121_200},
        {9, "", 47_673_900, -122_121_400}
      ]
    },
    %{
      pre_direction: "",
      name: "POLE",
      type: "",
      suf_direction: "",
      city: "",
      addresses: [{10, "", 90_000_000, 180_000_000}, {12, "", -90_000_000, -180_000_000}]
    },
    %{
      pre_direction: "N",
      name: "ZED",
      type: "CT",
      suf_direction: "",
      city: "SEATTLE",
      addresses: [{999_999_999, "Z", 0, 0}]
    }
  ]

  @index_entries [
    %{prefix: "", byte_size: 4_096, sha256: "a"},
    %{prefix: "MAIN$", byte_size: 1, sha256: "b"},
    %{prefix: "MAIN", byte_size: 4_294_967_295, sha256: "c"},
    %{prefix: "ÉCOLE", byte_size: 131_072, sha256: "d"}
  ]

  @doc "The directory the fixture files are in."
  @spec directory() :: String.t()
  def directory, do: @directory

  @doc "The streets of the shard, in the order of their name keys, as `Gobusgo.Addresses.Accumulator.finish/1` returns them."
  @spec streets() :: [Gobusgo.Addresses.Accumulator.street()]
  def streets do
    for street <- @streets do
      fields = Map.take(street, [:pre_direction, :name, :type, :suf_direction])

      rows =
        for {number, suffix, lat, lon} <- street.addresses, into: <<>> do
          Rows.pack(%{
            number: number,
            suffix: suffix,
            lat_microdegrees: lat,
            lon_microdegrees: lon
          })
        end

      %{street: fields, name_key: Normalize.name_key(fields), city: street.city, rows: rows}
    end
  end

  @doc "The entries of the index, each with a hash of 64 hexadecimal digits."
  @spec index_entries() :: [Format.index_entry()]
  def index_entries do
    for entry <- @index_entries do
      %{entry | sha256: :crypto.hash(:sha256, entry.sha256) |> Base.encode16(case: :lower)}
    end
  end

  @doc "Returns the expanded container of the shard."
  @spec encode_shard() :: binary()
  def encode_shard, do: Format.encode_shard(streets())

  @doc "Returns the expanded container of the index."
  @spec encode_index() :: binary()
  def encode_index, do: Format.encode_index(index_entries())

  @doc "Returns what a reader decodes from the files, as the JSON of `expected.json`."
  @spec expected() :: map()
  def expected do
    %{"shard" => expected_shard(), "index" => expected_index()}
  end

  defp expected_shard do
    addresses = Enum.flat_map(@streets, & &1.addresses)

    %{
      "streetCount" => length(@streets),
      "names" => Enum.map(@streets, & &1.name),
      "preDirections" => Enum.map(@streets, & &1.pre_direction),
      "types" => Enum.map(@streets, & &1.type),
      "sufDirections" => Enum.map(@streets, & &1.suf_direction),
      "cities" => Enum.map(@streets, & &1.city),
      "addressStarts" => [0 | @streets |> Enum.map(&length(&1.addresses)) |> Enum.scan(0, &+/2)],
      "numbers" => for({number, _suffix, _lat, _lon} <- addresses, do: number),
      "suffixes" => for({_number, suffix, _lat, _lon} <- addresses, do: suffix),
      "positions" => Enum.flat_map(addresses, fn {_number, _suffix, lat, lon} -> [lat, lon] end)
    }
  end

  defp expected_index do
    entries = index_entries()

    %{
      "shardCount" => length(entries),
      "prefixes" => Enum.map(entries, & &1.prefix),
      "paths" => Enum.map(entries, &Gobusgo.Packed.file_name(%{kind: 3, sha256: &1.sha256})),
      "byteSizes" => Enum.map(entries, & &1.byte_size),
      "sha256s" => Enum.map(entries, & &1.sha256)
    }
  end
end
