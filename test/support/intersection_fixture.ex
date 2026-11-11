defmodule Gobusgo.Test.IntersectionFixture do
  @moduledoc """
  The records of the shared intersection fixtures under
  `test/fixtures/intersections/v1/`: `shard.bin`, an intersection shard as
  the packed container holds it, `index.bin`, an intersection index, each
  also as one gzip stream (`.bin.gz`), and `expected.json`, what a reader
  decodes from each.

  The shard holds six streets: the four of downtown Seattle's Pike, Pine,
  3rd, and 4th that cross one another, a street at the corners of the globe
  with a multibyte other street, and a street of one crossing. The index
  holds the empty prefix, a prefix a longer prefix extends, the own-name
  mark, and a size at 32 bits.
  """

  alias Gobusgo.Intersections.Format
  alias Gobusgo.Intersections.Names
  alias Gobusgo.Intersections.Streets

  @directory Path.expand("../fixtures/intersections/v1", __DIR__)

  @pike_third {47_610_700, -122_337_100}
  @pike_fourth {47_611_200, -122_335_700}
  @pine_third {47_612_000, -122_336_500}
  @pine_fourth {47_612_500, -122_335_100}

  @streets [
    {"3RD AVE", [{"PIKE ST", @pike_third}, {"PINE ST", @pine_third}]},
    {"4TH AVE", [{"PIKE ST", @pike_fourth}, {"PINE ST", @pine_fourth}]},
    {"PIKE ST", [{"3RD AVE", @pike_third}, {"4TH AVE", @pike_fourth}]},
    {"PINE ST", [{"3RD AVE", @pine_third}, {"4TH AVE", @pine_fourth}]},
    {"POLE",
     [{"ÉQUATEUR", {90_000_000, 180_000_000}}, {"MERIDIAN", {-90_000_000, -180_000_000}}]},
    {"ZED CT", [{"3RD AVE", {0, 0}}]}
  ]

  @index_entries [
    %{prefix: "", name: "intersections-a.bin.gz", byte_size: 4_096, sha256: "a"},
    %{prefix: "PIKE$", name: "intersections-b.bin.gz", byte_size: 1, sha256: "b"},
    %{prefix: "PIKE", name: "intersections-c.bin.gz", byte_size: 4_294_967_295, sha256: "c"},
    %{prefix: "ÉCOLE", name: "intersections-d.bin.gz", byte_size: 131_072, sha256: "d"}
  ]

  @doc "The directory the fixture files are in."
  @spec directory() :: String.t()
  def directory, do: @directory

  @doc "The streets of the shard, in the order of their shard keys, as `Gobusgo.Intersections.Streets.group/1` returns them."
  @spec streets() :: [Streets.street()]
  def streets do
    for {key, crossings} <- @streets do
      list =
        for {other, {lat, lon}} <- crossings do
          %{other: other, lat_microdegrees: lat, lon_microdegrees: lon}
        end

      %{key: key, name_key: Names.name_key(key), crossings: list}
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
    crossings = Enum.flat_map(@streets, fn {_key, crossings} -> crossings end)

    %{
      "streetCount" => length(@streets),
      "keys" => for({key, _crossings} <- @streets, do: key),
      "crossingStarts" => [
        0 | @streets |> Enum.map(fn {_key, list} -> length(list) end) |> Enum.scan(0, &+/2)
      ],
      "others" => for({other, _point} <- crossings, do: other),
      "positions" => Enum.flat_map(crossings, fn {_other, {lat, lon}} -> [lat, lon] end)
    }
  end

  defp expected_index do
    entries = index_entries()

    %{
      "shardCount" => length(entries),
      "prefixes" => Enum.map(entries, & &1.prefix),
      "paths" => Enum.map(entries, & &1.name),
      "byteSizes" => Enum.map(entries, & &1.byte_size),
      "sha256s" => Enum.map(entries, & &1.sha256)
    }
  end
end
