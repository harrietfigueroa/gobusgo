defmodule Gobusgo.WalkGraph.Tiles do
  @tile_lat_units 1_000
  @tile_lon_units 1_500

  @moduledoc """
  The grid the walk graph is sharded by: a tile is a cell of
  #{@tile_lat_units} units of latitude by
  #{@tile_lon_units} of longitude, numbered `{row, column}` by the
  floor of a position over the cell's size, so a negative position has a
  negative number. Everything here is pure.

  A piece of way belongs to the tile of its first point and is cut where it
  leaves the tile: `cut/2` ends a piece at the first point in another tile,
  which the next piece starts from, so the two share that point and a reader
  joins them by position. No point is invented, and a piece holds no point
  of another tile but its last.
  """

  @type tile :: {integer(), integer()}
  @type point :: {integer(), integer()}
  @type sizes :: %{lat: pos_integer(), lon: pos_integer()}

  @doc "The cell size the shards use, in units."
  @spec sizes() :: sizes()
  def sizes, do: %{lat: @tile_lat_units, lon: @tile_lon_units}

  @doc "The tile that holds `point`."
  @spec tile_of(point(), sizes()) :: tile()
  def tile_of({lat, lon}, %{lat: lat_size, lon: lon_size}) do
    {Integer.floor_div(lat, lat_size), Integer.floor_div(lon, lon_size)}
  end

  @doc """
  The pieces of the path through `points`, each `{tile, points}` of the tile
  of its first point, in path order. A path of fewer than two points has no
  piece.
  """
  @spec cut([point()], sizes()) :: [{tile(), [point(), ...]}]
  def cut([_first, _second | _rest] = points, sizes) when is_map(sizes) do
    cut(points, sizes, [])
  end

  def cut(points, sizes) when is_list(points) and is_map(sizes), do: []

  # A path's last position that a piece already ended at starts no piece.
  defp cut([_only], _sizes, pieces), do: Enum.reverse(pieces)

  defp cut([first | rest], sizes, pieces) do
    tile = tile_of(first, sizes)
    {inside, leaving} = Enum.split_while(rest, &(tile_of(&1, sizes) == tile))

    case leaving do
      [] ->
        Enum.reverse([{tile, [first | inside]} | pieces])

      [exit | _after_exit] ->
        piece = {tile, [first | inside] ++ [exit]}
        cut(leaving, sizes, [piece | pieces])
    end
  end
end
