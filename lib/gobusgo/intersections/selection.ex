defmodule Gobusgo.Intersections.Selection do
  @keys_per_node_max 8
  @microdegrees 1_000_000

  @moduledoc """
  Finds the nodes that two differently named roads share in the lines of an
  OPL export (`Gobusgo.Intersections.Opl`).

  `run/2` takes a function that returns a fresh stream of the export's
  lines, since it reads them twice: the ways first, to find every node that
  ways of two keys (`Gobusgo.Intersections.Names`) both list, then the
  nodes, for the positions of the shared ones alone. A way is a road when
  its `highway` value is one of `Gobusgo.Intersections.Classification`'s and
  it has a `name` whose key is supported; the keys of one node are at most
  #{@keys_per_node_max}, and a node with more is counted as `crowded` and
  left out. Two ways of one key, such as a street split in two, share no
  crossing.

  The first pass keeps one entry per node of the roads in an ETS table that
  lives only for the call, so the run holds an integer per node and not a
  string; that table is why this module is not pure, though it holds and
  returns nothing but values.

  The options are `:bounds` (`Gobusgo.Places.Bounds`), `:service_roads`, and
  `:lines`, the stream function. The result is `%{nodes:, counts:}`: `nodes`
  are `%{id:, lat_microdegrees:, lon_microdegrees:, keys:}` in the order of
  their identifiers, with the sorted keys of the roads through them, and
  `counts` holds `ways_read`, `ways_wrong_class`, `ways_unnamed`,
  `ways_unsupported_name`, `ways_kept`, `road_nodes`, `shared_nodes`,
  `crowded_nodes`, `outside_nodes`, and `malformed_lines`.
  """

  alias Gobusgo.Intersections.Classification
  alias Gobusgo.Intersections.Names
  alias Gobusgo.Intersections.Opl
  alias Gobusgo.Places.Bounds

  @type shared_node :: %{
          id: integer(),
          lat_microdegrees: integer(),
          lon_microdegrees: integer(),
          keys: [String.t(), ...]
        }

  @type request :: %{
          lines: (-> Enumerable.t(String.t())),
          bounds: Bounds.t(),
          service_roads: boolean()
        }

  @doc "The nodes the roads of the export share inside the bounds, with the counts of what became of each line."
  @spec run(request()) :: %{nodes: [shared_node()], counts: map()}
  def run(%{lines: lines, bounds: bounds, service_roads: service_roads} = request)
      when is_function(lines, 0) and is_boolean(service_roads) do
    roads = :ets.new(:intersection_road_nodes, [:set, :private])

    try do
      first = read_ways(request, roads)
      shared = shared_ids(first.keys_by_node)
      {nodes, second} = read_nodes(%{lines: lines, bounds: bounds, shared: shared})

      counts =
        Map.merge(first.counts, %{
          road_nodes: :ets.info(roads, :size),
          shared_nodes: map_size(shared),
          crowded_nodes: first.crowded,
          outside_nodes: second.outside,
          malformed_lines: first.counts.malformed_lines + second.malformed
        })

      %{nodes: nodes, counts: counts}
    after
      :ets.delete(roads)
    end
  end

  # Pass one: the key of the first road through each node, and the keys of the
  # others where they differ.
  defp read_ways(%{lines: lines, service_roads: service_roads}, roads) do
    initial = %{
      counts: %{
        ways_read: 0,
        ways_wrong_class: 0,
        ways_unnamed: 0,
        ways_unsupported_name: 0,
        ways_kept: 0,
        malformed_lines: 0
      },
      keys_by_node: %{},
      key_ids: %{},
      service_roads: service_roads,
      roads: roads
    }

    state = Enum.reduce(lines.(), initial, &read_way_line/2)
    keys = state.key_ids |> Map.new(fn {key, id} -> {id, key} end)
    crowded = Enum.count(state.keys_by_node, fn {_node, ids} -> :crowded == ids end)

    keys_by_node =
      for {node, ids} <- state.keys_by_node, ids != :crowded, into: %{} do
        {node, ids |> Enum.map(&Map.fetch!(keys, &1)) |> Enum.sort()}
      end

    %{counts: state.counts, keys_by_node: keys_by_node, crowded: crowded}
  end

  defp read_way_line(line, state) do
    case Opl.way(line) do
      :skip -> state
      :malformed -> update_in(state.counts.malformed_lines, &(&1 + 1))
      {:ok, way} -> read_way(way, update_in(state.counts.ways_read, &(&1 + 1)))
    end
  end

  defp read_way(%{tags: tags} = way, state) do
    highway = Map.get(tags, "highway")
    name = Map.get(tags, "name")

    cond do
      not Classification.road?(highway, state.service_roads) ->
        update_in(state.counts.ways_wrong_class, &(&1 + 1))

      is_nil(name) ->
        update_in(state.counts.ways_unnamed, &(&1 + 1))

      true ->
        keep_way(way, name, state)
    end
  end

  defp keep_way(way, name, state) do
    case Names.key(name) do
      :unsupported ->
        update_in(state.counts.ways_unsupported_name, &(&1 + 1))

      {:ok, %{key: key}} ->
        {key_id, key_ids} = intern(state.key_ids, key)
        state = %{state | key_ids: key_ids}
        state = update_in(state.counts.ways_kept, &(&1 + 1))
        Enum.reduce(way.node_ids, state, &add_node(&1, key_id, &2))
    end
  end

  defp intern(key_ids, key) do
    case Map.fetch(key_ids, key) do
      {:ok, id} ->
        {id, key_ids}

      :error ->
        id = map_size(key_ids)
        {id, Map.put(key_ids, key, id)}
    end
  end

  # The table holds the first key of a node; a node seen under another key is
  # moved to `keys_by_node`, where its keys accumulate.
  defp add_node(node, key_id, state) do
    case :ets.insert_new(state.roads, {node, key_id}) do
      true -> state
      false -> add_second_key(node, key_id, state)
    end
  end

  defp add_second_key(node, key_id, state) do
    [{^node, first_id}] = :ets.lookup(state.roads, node)

    case Map.get(state.keys_by_node, node, [first_id]) do
      :crowded ->
        state

      ids ->
        grow(node, ids, key_id, state)
    end
  end

  defp grow(node, ids, key_id, state) do
    cond do
      key_id in ids -> state
      length(ids) >= @keys_per_node_max -> put_in(state.keys_by_node[node], :crowded)
      true -> put_in(state.keys_by_node[node], [key_id | ids])
    end
  end

  defp shared_ids(keys_by_node) do
    for {node, keys} <- keys_by_node, length(keys) >= 2, into: %{}, do: {node, keys}
  end

  # Pass two: the positions of the shared nodes, by identifier.
  defp read_nodes(%{lines: lines, bounds: bounds, shared: shared}) do
    initial = %{nodes: [], outside: 0, malformed: 0}

    state =
      Enum.reduce(lines.(), initial, fn line, state ->
        read_node_line(line, %{shared: shared, bounds: bounds}, state)
      end)

    nodes = Enum.sort_by(state.nodes, & &1.id)
    {nodes, Map.take(state, [:outside, :malformed])}
  end

  defp read_node_line(line, context, state) do
    case Opl.node_id(line) do
      :skip -> state
      :malformed -> %{state | malformed: state.malformed + 1}
      {:ok, id} -> read_shared(line, {id, Map.get(context.shared, id)}, context, state)
    end
  end

  defp read_shared(_line, {_id, nil}, _context, state), do: state

  defp read_shared(line, {id, keys}, %{bounds: bounds}, state) do
    case Opl.node(line) do
      {:ok, %{lat: lat, lon: lon}} ->
        if Bounds.contains?(bounds, %{lat: lat, lon: lon}) do
          node = %{
            id: id,
            lat_microdegrees: round(lat * @microdegrees),
            lon_microdegrees: round(lon * @microdegrees),
            keys: keys
          }

          %{state | nodes: [node | state.nodes]}
        else
          %{state | outside: state.outside + 1}
        end

      _other ->
        %{state | malformed: state.malformed + 1}
    end
  end
end
