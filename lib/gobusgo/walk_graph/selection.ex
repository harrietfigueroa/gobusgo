defmodule Gobusgo.WalkGraph.Selection do
  @units_per_degree Gobusgo.WalkGraph.Format.units_per_degree()
  @junction_references_min 2
  @point_bytes 8
  @position_shift 30

  @moduledoc """
  Reads the walkable ways of an OPL export (`Gobusgo.Intersections.Opl`) into
  the pieces of way each tile holds.

  `run/1` takes a function that returns a fresh stream of the export's
  lines, since it reads them three times: the nodes, whose positions go in
  an ETS table that lives for the call; the ways, to count how many ways
  list each node, where a node that two ways list, or that ends a way, is a
  junction; and the ways again, to cut each into edges
  (`Gobusgo.WalkGraph.Edges`) and each edge into pieces by tile
  (`Gobusgo.WalkGraph.Tiles`). A way is walkable by
  `Gobusgo.WalkGraph.Classification`. The ETS tables are why this module is
  not pure, though it holds and returns nothing but values.

  The result is `%{tiles:, counts:}`. `tiles` maps a tile to its pieces, each
  `{class, points}` with `class` the number of the way's class and `points`
  a binary of 8 bytes a point, latitude then longitude as signed 32-bit
  integers in the graph's units, the 100,000th part of a degree
  (`Gobusgo.WalkGraph.Format.units_per_degree/0`). Each edge is simplified
  (`Gobusgo.WalkGraph.Simplify`) before it is cut by tile, to
  `simplify_units`. `counts` holds `ways_read`, `ways_kept`,
  `ways_excluded` (a map from reason), `ways_missing_nodes`, `nodes`,
  `junction_nodes`, `pieces`, `points`, and `malformed_lines`.
  """

  alias Gobusgo.Intersections.Opl
  alias Gobusgo.WalkGraph.Classification
  alias Gobusgo.WalkGraph.Edges
  alias Gobusgo.WalkGraph.Simplify
  alias Gobusgo.WalkGraph.Tiles

  @type piece :: {0..4, binary()}
  @type request :: %{
          lines: (-> Enumerable.t(String.t())),
          tile_sizes: Tiles.sizes(),
          simplify_units: number()
        }

  @doc "The pieces of the walkable ways of the export, by tile, with the counts of what became of each line."
  @spec run(request()) :: %{tiles: %{Tiles.tile() => [piece()]}, counts: map()}
  def run(%{lines: lines, tile_sizes: tile_sizes, simplify_units: simplify_units})
      when is_function(lines, 0) do
    positions = :ets.new(:walk_graph_positions, [:set, :private])
    references = :ets.new(:walk_graph_references, [:set, :private])

    try do
      malformed_nodes = read_nodes(lines, positions)
      reference_counts = count_references(lines, references)

      cut =
        cut_ways(%{
          lines: lines,
          tile_sizes: tile_sizes,
          simplify_units: simplify_units,
          positions: positions,
          references: references
        })

      counts = %{
        ways_read: reference_counts.ways_read,
        ways_kept: reference_counts.ways_kept,
        ways_excluded: reference_counts.excluded,
        ways_missing_nodes: cut.missing_nodes,
        nodes: :ets.info(positions, :size),
        junction_nodes: junction_count(references),
        pieces: cut.pieces,
        points: cut.points,
        malformed_lines: malformed_nodes + reference_counts.malformed
      }

      %{tiles: cut.tiles, counts: counts}
    after
      :ets.delete(positions)
      :ets.delete(references)
    end
  end

  defp junction_count(references) do
    match_spec = [{{:_, :"$1"}, [{:>=, :"$1", @junction_references_min}], [true]}]
    :ets.select_count(references, match_spec)
  end

  # Pass one: every node's position, packed into one integer.
  defp read_nodes(lines, positions) do
    Enum.reduce(lines.(), 0, fn line, malformed ->
      case Opl.node(line) do
        {:ok, %{id: id, lat: lat, lon: lon}} ->
          :ets.insert(
            positions,
            {id, pack(round(lat * @units_per_degree), round(lon * @units_per_degree))}
          )

          malformed

        :skip ->
          malformed

        :malformed ->
          malformed + 1
      end
    end)
  end

  defp pack(lat, lon),
    do:
      (lat + 90 * @units_per_degree) * Bitwise.bsl(1, @position_shift) + lon +
        180 * @units_per_degree

  defp unpack(packed) do
    base = Bitwise.bsl(1, @position_shift)
    lat = Integer.floor_div(packed, base) - 90 * @units_per_degree
    lon = Integer.mod(packed, base) - 180 * @units_per_degree
    {lat, lon}
  end

  # Pass two: how many times ways list each node, the ends of a way twice.
  defp count_references(lines, references) do
    initial = %{ways_read: 0, ways_kept: 0, excluded: %{}, malformed: 0}

    Enum.reduce(lines.(), initial, fn line, state ->
      case Opl.way(line) do
        :skip -> state
        :malformed -> %{state | malformed: state.malformed + 1}
        {:ok, way} -> reference_way(way, %{state | ways_read: state.ways_read + 1}, references)
      end
    end)
  end

  defp reference_way(%{tags: tags, node_ids: node_ids}, state, references) do
    case Classification.class(tags) do
      {:excluded, reason} ->
        %{state | excluded: Map.update(state.excluded, reason, 1, &(&1 + 1))}

      {:ok, _class} ->
        for id <- node_ids, do: :ets.update_counter(references, id, 1, {id, 0})
        for id <- ends(node_ids), do: :ets.update_counter(references, id, 1, {id, 0})
        %{state | ways_kept: state.ways_kept + 1}
    end
  end

  defp ends([]), do: []
  defp ends([only]), do: [only]
  defp ends([first | rest]), do: [first, List.last(rest)]

  # Pass three: the pieces.
  defp cut_ways(context) do
    initial = %{tiles: %{}, pieces: 0, points: 0, missing_nodes: 0}

    Enum.reduce(context.lines.(), initial, fn line, state ->
      case Opl.way(line) do
        :skip -> state
        {:ok, way} -> cut_way(way, state, context)
        _unusable -> state
      end
    end)
  end

  defp cut_way(%{tags: tags, node_ids: node_ids}, state, context) do
    case Classification.class(tags) do
      {:excluded, _reason} -> state
      {:ok, class} -> cut_walkable(%{class: class, node_ids: node_ids}, state, context)
    end
  end

  defp cut_walkable(%{class: class, node_ids: node_ids}, state, context) do
    vertices = vertices(node_ids, context)

    if length(vertices) == length(node_ids) do
      vertices
      |> Edges.cut()
      |> Enum.map(
        &Simplify.run(&1, %{
          tolerance: context.simplify_units,
          units_per_degree: @units_per_degree
        })
      )
      |> Enum.flat_map(&Tiles.cut(&1, context.tile_sizes))
      |> Enum.reduce(state, &keep_piece(&1, &2, Classification.number(class)))
    else
      %{state | missing_nodes: state.missing_nodes + 1}
    end
  end

  defp vertices(node_ids, %{positions: positions, references: references}) do
    for id <- node_ids, [{_id, packed}] <- [:ets.lookup(positions, id)] do
      {lat, lon} = unpack(packed)
      [{_id, count}] = :ets.lookup(references, id)
      {lat, lon, count >= @junction_references_min}
    end
  end

  defp keep_piece({tile, points}, state, class) do
    binary = for {lat, lon} <- points, into: <<>>, do: <<lat::signed-32, lon::signed-32>>
    piece = {class, binary}

    %{
      state
      | tiles: Map.update(state.tiles, tile, [piece], &[piece | &1]),
        pieces: state.pieces + 1,
        points: state.points + div(byte_size(binary), @point_bytes)
    }
  end
end
