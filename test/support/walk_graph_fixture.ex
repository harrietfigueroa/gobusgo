defmodule Gobusgo.Test.WalkGraphFixture do
  @moduledoc """
  The records of the shared walk graph fixtures under
  `test/fixtures/walk_graph/v1/`: `shard-west.bin` and `shard-east.bin`, two
  neighboring shards as the packed container holds them, `index.bin`, an
  index, each also as one gzip stream (`.bin.gz`), and `expected.json`, what a
  reader decodes from each.

  The west shard (tile 4761, -8156) is a grid of streets near downtown
  Seattle, three columns by two rows of crossings, with the middle column's
  link between the rows missing, a footbridge, steps, a crossing, and an
  island of way that joins nothing. A street runs east out of the tile and
  the east shard (tile 4761, -8155) takes it up, so a path across the two
  shards meets at the position they share. The index names those two tiles,
  a tile two columns on that a run does not reach, and a run of two tiles
  at a negative row.
  """

  alias Gobusgo.WalkGraph.Classification
  alias Gobusgo.WalkGraph.Format

  @directory Path.expand("../fixtures/walk_graph/v1", __DIR__)
  @build_id "0123456789abcdef"

  # Row 1 and row 2 of the grid, and its three columns, in units.
  @north 4_761_450
  @south 4_761_300
  @west_column -12_233_600
  @middle_column -12_233_400
  @east_column -12_233_200
  @beyond_column -12_232_400
  @far_column -12_231_800

  @west_pieces [
    {:street, [{@north, @west_column}, {@north, @middle_column}]},
    {:street, [{@north, @middle_column}, {@north, @east_column}]},
    {:street, [{@south, @west_column}, {@south, @middle_column}]},
    {:street, [{@south, @middle_column}, {@south, @east_column}]},
    {:sidewalk, [{@north, @west_column}, {4_761_380, @west_column}, {@south, @west_column}]},
    {:crossing, [{@north, @east_column}, {4_761_380, @east_column}, {@south, @east_column}]},
    {:path, [{@south, @east_column}, {@south, @beyond_column}]},
    {:steps, [{4_761_100, @west_column}, {4_761_130, @west_column}, {4_761_160, -12_233_580}]},
    {:path, [{4_761_800, @west_column}, {4_761_800, @middle_column}]}
  ]

  @east_pieces [
    {:street, [{@south, @beyond_column}, {@south, @far_column}]}
  ]

  @tiles [{4_761, -8_156}, {4_761, -8_155}, {4_761, -8_153}, {-3, -5}, {-3, -4}]

  @doc "The directory the fixture files are in."
  @spec directory() :: String.t()
  def directory, do: @directory

  @doc "The build identifier of the index."
  @spec build_id() :: String.t()
  def build_id, do: @build_id

  @doc "The tiles of the index, in the order of their rows and then columns."
  @spec tiles() :: [Gobusgo.WalkGraph.Tiles.tile()]
  def tiles, do: Enum.sort(@tiles)

  @doc "The pieces of the shard `name`, `:west` or `:east`, in the order they are stored."
  @spec pieces(:west | :east) :: [Format.piece()]
  def pieces(:west), do: to_pieces(@west_pieces)
  def pieces(:east), do: to_pieces(@east_pieces)

  defp to_pieces(list) do
    for {class, points} <- list do
      %{class: Classification.number(class), points: points}
    end
  end

  @doc "Returns the expanded container of the shard `name`."
  @spec encode_shard(:west | :east) :: binary()
  def encode_shard(name), do: Format.encode_shard(pieces(name))

  @doc "Returns the expanded container of the index."
  @spec encode_index() :: binary()
  def encode_index, do: Format.encode_index(%{build_id: @build_id, tiles: tiles()})

  @doc "Returns what a reader decodes from the files, as the JSON of `expected.json`."
  @spec expected() :: map()
  def expected do
    %{
      "shardWest" => expected_shard(:west),
      "shardEast" => expected_shard(:east),
      "index" => %{
        "buildId" => @build_id,
        "tileKeys" => for({row, column} <- tiles(), do: "#{row}_#{column}")
      }
    }
  end

  defp expected_shard(name) do
    pieces = pieces(name)

    %{
      "pieceCount" => length(pieces),
      "classes" => Enum.map(pieces, & &1.class),
      "pieceStarts" => [0 | pieces |> Enum.map(&length(&1.points)) |> Enum.scan(0, &+/2)],
      "points" =>
        Enum.flat_map(pieces, fn piece -> Enum.flat_map(piece.points, &Tuple.to_list/1) end)
    }
  end
end
