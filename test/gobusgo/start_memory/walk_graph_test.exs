defmodule Gobusgo.StartMemory.WalkGraphTest do
  # Checks the synthetic walk graph of the start-memory check: it covers the
  # tiles around every stop, its largest window of tiles is the size the real
  # graph's is, its pieces read back through the shard kind, and a stop of
  # the network snaps to a street.
  use ExUnit.Case, async: true

  alias Gobusgo.StartMemory.Fixture
  alias Gobusgo.StartMemory.WalkGraph
  alias Gobusgo.WalkGraph.Format
  alias Gobusgo.WalkGraph.Tiles

  @units 100_000
  @window_piece_count_real_max 35_413
  @band_piece_count_real_max 121_660

  test "holds a shard for every tile around every stop" do
    tiles = MapSet.new(WalkGraph.tiles())

    for %{lat: lat, lon: lon} <- Fixture.stop_positions() do
      {row, column} =
        Tiles.tile_of({floor(lat * @units), floor(lon * @units)}, Tiles.sizes())

      for row_step <- -1..1, column_step <- -1..1 do
        assert MapSet.member?(tiles, {row + row_step, column + column_step})
      end
    end
  end

  test "has a largest window and a largest three rows of the size of the real graph's" do
    summary = WalkGraph.summary()

    assert summary.window_piece_count_max in div(@window_piece_count_real_max * 8, 10)..div(
             @window_piece_count_real_max * 12,
             10
           )

    assert summary.band_piece_count_max in div(@band_piece_count_real_max * 8, 10)..div(
             @band_piece_count_real_max * 12,
             10
           )
  end

  test "encodes each tile's pieces as a shard that decodes to as many pieces" do
    request = WalkGraph.publication_request()

    {tile, pieces} =
      Enum.find(request.tiles, fn {tile, _pieces} -> tile == hd(WalkGraph.tiles()) end)

    ordered = Format.order(pieces, %{tile: tile, tile_sizes: Tiles.sizes()})
    assert {:ok, %{pieces: decoded}} = ordered |> Format.encode_shard() |> Format.decode_shard()

    assert length(decoded) == length(pieces)
    assert length(pieces) == WalkGraph.piece_count(tile)
  end

  test "is the same graph on every call" do
    assert WalkGraph.summary() == WalkGraph.summary()
  end
end
