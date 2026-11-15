defmodule Gobusgo.StartMemory.WalkGraph do
  @built_at ~U[2026-11-14 12:00:00Z]
  @source_date "2026-11-08T21:21:00Z"
  @class_street 4
  @base_piece_count 450
  @base_piece_count_span 1_300
  @core_piece_count 3_800
  @ring_piece_count 2_600
  @outer_piece_count 1_200
  @center_latitude 47.6062
  @center_longitude -122.3321
  @tile_window_radius 1

  @moduledoc """
  A synthetic walk graph over the stops of `Gobusgo.StartMemory.Fixture`, for
  the start-memory check to measure the walking links on. It holds a shard
  for every tile that has a stop and every tile around one, each a lattice of
  streets whose piece count is drawn per tile as the real graph's are: a base
  of #{@base_piece_count} to #{@base_piece_count + @base_piece_count_span}
  pieces, and a dense core around the center of the network, #{@core_piece_count}
  more in its tile, #{@ring_piece_count} in the eight around it, and
  #{@outer_piece_count} in the sixteen outside those, so the window of tiles
  around the center is the largest, as downtown Seattle's is in the real graph.

  The pieces of a tile are its own, joined to no other tile's, which is all a
  search reads. Everything here is pure, and the same call gives the same
  graph.
  """

  alias Gobusgo.StartMemory.Fixture
  alias Gobusgo.WalkGraph.Publication
  alias Gobusgo.WalkGraph.Tiles

  @units_per_degree Gobusgo.WalkGraph.Format.units_per_degree()

  @type summary :: %{
          tile_count: pos_integer(),
          piece_count: pos_integer(),
          window_piece_count_max: pos_integer(),
          band_piece_count_max: pos_integer()
        }

  @doc "The tiles of the graph: every tile with a stop and every tile around one, in order."
  @spec tiles() :: [Tiles.tile()]
  def tiles do
    stop_tiles =
      Fixture.stop_positions()
      |> Enum.map(&tile_of/1)
      |> Enum.uniq()

    for {row, column} <- stop_tiles,
        row_step <- -@tile_window_radius..@tile_window_radius,
        column_step <- -@tile_window_radius..@tile_window_radius,
        uniq: true,
        do: {row + row_step, column + column_step}
  end

  @doc "How many pieces the shard of `tile` holds: those of the lattice that holds at least the tile's drawn count."
  @spec piece_count(Tiles.tile()) :: pos_integer()
  def piece_count(tile) do
    side = side(tile)
    2 * side * (side - 1)
  end

  defp side(tile), do: ceil(:math.sqrt(drawn_count(tile) / 2)) + 1

  defp drawn_count({row, column} = tile) do
    {center_row, center_column} = tile_of(%{lat: @center_latitude, lon: @center_longitude})
    distance = max(abs(row - center_row), abs(column - center_column))
    base = @base_piece_count + :erlang.phash2(tile, @base_piece_count_span)

    base +
      case distance do
        0 -> @core_piece_count
        1 -> @ring_piece_count
        2 -> @outer_piece_count
        _far -> 0
      end
  end

  @doc "The counts of the graph: its tiles and pieces, the most pieces of a 3 by 3 window of tiles, and of three rows of tiles."
  @spec summary() :: summary()
  def summary do
    tiles = tiles()
    counts = Map.new(tiles, &{&1, piece_count(&1)})

    window_counts =
      for {row, column} <- tiles do
        for row_step <- -1..1, column_step <- -1..1, reduce: 0 do
          sum -> sum + Map.get(counts, {row + row_step, column + column_step}, 0)
        end
      end

    band_counts =
      for {row, _column} <- Enum.uniq_by(tiles, &elem(&1, 0)) do
        for {{tile_row, _column}, count} <- counts, abs(tile_row - row) <= 1, reduce: 0 do
          sum -> sum + count
        end
      end

    %{
      tile_count: length(tiles),
      piece_count: counts |> Map.values() |> Enum.sum(),
      window_piece_count_max: Enum.max(window_counts),
      band_piece_count_max: Enum.max(band_counts)
    }
  end

  @doc """
  The request `Gobusgo.WalkGraph.Publication.publish/2` takes: every tile's
  pieces, each `{class, positions}` as the publication packs them.
  """
  @spec publication_request() :: Publication.request()
  def publication_request do
    tiles = Map.new(tiles(), fn tile -> {tile, pieces(tile)} end)
    %{source_date: @source_date, tiles: tiles, built_at: @built_at}
  end

  # A lattice of `side` by `side` nodes across the tile, a street between
  # each pair of neighbors, with a bend between the two nodes so a piece holds
  # three positions as the real graph's hold about three.
  defp pieces({row, column} = tile) do
    side = side(tile)
    sizes = Tiles.sizes()
    lat_step = max(div(sizes.lat, side), 2)
    lon_step = max(div(sizes.lon, side), 2)

    for i <- 0..(side - 1), j <- 0..(side - 1), direction <- [:along, :across], reduce: [] do
      pieces ->
        lat = row * sizes.lat + i * lat_step
        lon = column * sizes.lon + j * lon_step

        case street(
               direction,
               %{i: i, j: j, side: side, lat: lat, lon: lon},
               {lat_step, lon_step}
             ) do
          nil -> pieces
          points -> [packed(points) | pieces]
        end
    end
  end

  defp street(:along, %{j: j, side: side, lat: lat, lon: lon}, {_lat_step, lon_step})
       when j < side - 1 do
    [{lat, lon}, {lat + 1, lon + div(lon_step, 2)}, {lat, lon + lon_step}]
  end

  defp street(:across, %{i: i, side: side, lat: lat, lon: lon}, {lat_step, _lon_step})
       when i < side - 1 do
    [{lat, lon}, {lat + div(lat_step, 2), lon + 1}, {lat + lat_step, lon}]
  end

  defp street(_direction, _node, _steps), do: nil

  defp packed(points) do
    {@class_street, for({lat, lon} <- points, into: <<>>, do: <<lat::signed-32, lon::signed-32>>)}
  end

  defp tile_of(%{lat: lat, lon: lon}) do
    Tiles.tile_of({floor(lat * @units_per_degree), floor(lon * @units_per_degree)}, Tiles.sizes())
  end
end
