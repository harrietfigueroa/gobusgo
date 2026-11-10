defmodule Gobusgo.Test.PackedFixture do
  @moduledoc """
  The records of the shared packed container fixture under
  `test/fixtures/packed/core-v1/`: `fixture.bin`, the expanded container of
  the fixture kind, `fixture.bin.gz`, its gzip stream, and `expected.json`,
  what a reader decodes from it. Five records cover a string table with
  ASCII, multibyte text, and an empty string, a string used twice, a `u32`,
  an `i32`, and a `u16` column of string indexes, positions with a negative
  longitude, an unknown one, and both ends of the globe, paths with
  negative and positive deltas, a long jump, one point, and no point, and
  varints from 0 to the largest.
  """

  alias Gobusgo.Packed
  alias Gobusgo.Packed.Columns
  alias Gobusgo.Packed.Positions
  alias Gobusgo.Packed.StringTable

  @directory Path.expand("../fixtures/packed/core-v1", __DIR__)
  @kind 0
  @version 1
  @section_count 6

  @names [
    "Pike Place Market — 1st Ave",
    "Bothell–Everett",
    "",
    "Pike Place Market — 1st Ave",
    "Café Münster 東京"
  ]
  @u32s [0, 1, 70_000, 4_294_967_295, 16_384]
  @i32s [0, -1, 2_147_483_647, -2_147_483_648, 123_456_789]
  @positions [
    {47_606_200, -122_332_100},
    {47_610_000, -122_300_000},
    :unknown,
    {-33_868_800, 151_209_300},
    {0, 0}
  ]
  @paths [
    [
      {47_606_200, -122_332_100},
      {47_606_150, -122_332_000},
      {47_606_300, -122_331_900},
      {47_700_000, -122_000_000},
      {-33_868_800, 151_209_300}
    ],
    [{-90_000_000, 180_000_000}],
    []
  ]
  @varints [0, 127, 128, 16_383, 16_384, 4_294_967_295]

  @doc "The directory the fixture files are in."
  @spec directory() :: String.t()
  def directory, do: @directory

  @doc "The kind the fixture container has."
  @spec kind() :: non_neg_integer()
  def kind, do: @kind

  @doc "The version the fixture container has."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The sections the fixture kind holds after the string table."
  @spec section_count() :: pos_integer()
  def section_count, do: @section_count

  @doc "The record values the container holds."
  @spec records() :: map()
  def records do
    %{
      names: @names,
      u32s: @u32s,
      i32s: @i32s,
      positions: @positions,
      paths: @paths,
      varints: @varints
    }
  end

  @doc "Returns the expanded container of `records()`."
  @spec encode() :: binary()
  def encode do
    {indexes, table} =
      Enum.map_reduce(@names, StringTable.new(), &StringTable.intern(&2, &1))

    Packed.encode(%{
      kind: @kind,
      version: @version,
      record_count: length(@names),
      strings: StringTable.strings(table),
      sections: [
        Columns.encode(:u32, @u32s),
        Columns.encode(:i32, @i32s),
        Columns.encode(:u16, indexes),
        Positions.encode(@positions),
        Enum.map(@paths, &Positions.encode_path/1),
        Enum.map(@varints, &Gobusgo.Packed.Varint.encode/1)
      ]
    })
  end

  @doc "Returns the values a reader decodes from the container, as the JSON of `expected.json`."
  @spec expected() :: map()
  def expected do
    strings = Enum.uniq(@names)

    index_by_string =
      for {string, index} <- Enum.with_index(strings), into: %{}, do: {string, index}

    %{
      "kind" => @kind,
      "version" => @version,
      "recordCount" => length(@names),
      "strings" => strings,
      "u32" => @u32s,
      "i32" => @i32s,
      "u16Strings" => for(name <- @names, do: Map.fetch!(index_by_string, name)),
      "positions" =>
        for position <- @positions do
          case position do
            :unknown -> nil
            {lat, lon} -> [lat, lon]
          end
        end,
      "paths" => for(path <- @paths, do: for({lat, lon} <- path, do: [lat, lon])),
      "varints" => @varints
    }
  end
end
