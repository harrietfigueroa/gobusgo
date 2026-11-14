defmodule Gobusgo.WalkGraph.Search do
  @moduledoc """
  The shortest walk along the walk graph's pieces, over shards the caller
  has decoded. Everything here is pure: it reads no file and holds nothing,
  and every search is bounded by `limits`.

  `find_path/1` is one walk between two positions and mirrors
  `assets/js/core/walk_path.js`: the plane is tangent at the middle of the
  ends, an A* search runs between the snapped ends, and the answer is the
  length of the whole line. `reach/1` is one start and many targets in one
  search over a plane tangent at the start, bounded by a street length. The
  two agree to about a tenth of a meter, which is the difference of their
  planes, and a golden file made by the browser's code holds both to it.

  A position is a map of `lat` and `lon` in degrees. A shard is what
  `Gobusgo.WalkGraph.Format.decode_shard/1` returns. An answer is
  `{:found, meters}` or `{:no_path, reason}`, the reasons being `:off_graph`
  (an end is farther than the snap bound from every piece), `:disconnected`
  (no piece joins the snapped ends), `:cap_reached` (the search settled the
  node bound, or the shards hold more pieces than the piece bound),
  `:no_shards`, and, for `reach/1`, `:beyond_bound` (a connected target
  farther along streets than the street bound).
  """

  alias Gobusgo.Assert
  alias Gobusgo.WalkGraph.Format
  alias Gobusgo.WalkGraph.Graph
  alias Gobusgo.WalkGraph.Tiles

  @units_per_degree Format.units_per_degree()

  @type position :: Graph.position()
  @type shard :: %{pieces: [Format.piece()]}
  @type limits :: %{
          distance_meters_max: pos_integer(),
          margin_meters: pos_integer(),
          snap_meters_max: pos_integer(),
          tile_count_max: pos_integer(),
          edge_count_max: pos_integer(),
          visited_node_count_max: pos_integer(),
          street_meters_max: pos_integer(),
          target_count_max: pos_integer()
        }
  @type answer ::
          {:found, float()}
          | {:no_path, :off_graph | :disconnected | :cap_reached | :no_shards | :beyond_bound}

  @doc """
  The bounds the browser's search uses, and the street length and the
  number of targets a `reach/1` is bounded by.
  """
  @spec limits() :: limits()
  def limits do
    %{
      distance_meters_max: 1_500,
      margin_meters: 200,
      snap_meters_max: 100,
      tile_count_max: 16,
      edge_count_max: 250_000,
      visited_node_count_max: 30_000,
      street_meters_max: 600,
      target_count_max: 256
    }
  end

  @doc """
  The tiles of `index`, a `MapSet` of `{row, column}`, that the walk from
  `from` to `to` reads: the tiles the box of the two ends, widened by
  `limits.margin_meters`, touches and the index holds, in tile order; or
  `:too_far` for ends farther apart than `limits.distance_meters_max` or a
  box of more than `limits.tile_count_max` tiles.
  """
  @spec tiles_needed(%{from: position(), to: position(), index: MapSet.t(), limits: limits()}) ::
          {:tiles, [Tiles.tile()]} | :too_far
  def tiles_needed(%{from: from, to: to, index: index, limits: limits}) do
    assert_position(from)
    assert_position(to)
    plane = Graph.plane(from, to)
    {from_x, from_y} = Graph.to_plane(plane, from)
    {to_x, to_y} = Graph.to_plane(plane, to)
    straight_meters = :math.sqrt(:math.pow(to_x - from_x, 2) + :math.pow(to_y - from_y, 2))

    if straight_meters > limits.distance_meters_max do
      :too_far
    else
      box_tiles(%{from: from, to: to, plane: plane}, index, limits)
    end
  end

  @doc """
  The walk from `from` to `to` along the pieces of `shards`: `{:found,
  meters}`, the length of the line through the point each end snaps to, or
  `{:no_path, reason}`.
  """
  @spec find_path(%{from: position(), to: position(), shards: [shard()], limits: limits()}) ::
          answer()
  def find_path(%{from: from, to: to, shards: shards, limits: limits}) do
    assert_position(from)
    assert_position(to)
    pieces = Enum.flat_map(shards, & &1.pieces)
    piece_count = length(pieces)

    cond do
      piece_count == 0 -> {:no_path, :no_shards}
      piece_count > limits.edge_count_max -> {:no_path, :cap_reached}
      true -> plan_path(%{from: from, to: to, pieces: pieces, limits: limits})
    end
  end

  @doc """
  The walks from `from` to each of `targets`, one answer each in the order
  given, over `shards`, by one search from the start. A target connected to
  the start by street no longer than `limits.street_meters_max` is `{:found,
  meters}`; a connected one farther is `{:no_path, :beyond_bound}`. At most
  `limits.target_count_max` targets.
  """
  @spec reach(%{
          from: position(),
          targets: [position()],
          shards: [shard()],
          limits: limits()
        }) :: [answer()]
  def reach(%{from: from, targets: targets, shards: shards, limits: limits}) do
    assert_position(from)
    Enum.each(targets, &assert_position/1)

    Assert.condition(
      length(targets) <= limits.target_count_max,
      "#{length(targets)} targets are more than #{limits.target_count_max}"
    )

    pieces = Enum.flat_map(shards, & &1.pieces)
    piece_count = length(pieces)

    cond do
      targets == [] ->
        []

      piece_count == 0 ->
        Enum.map(targets, fn _target -> {:no_path, :no_shards} end)

      piece_count > limits.edge_count_max ->
        Enum.map(targets, fn _target -> {:no_path, :cap_reached} end)

      true ->
        reach_targets(%{from: from, targets: targets, pieces: pieces, limits: limits})
    end
  end

  defp assert_position(%{lat: lat, lon: lon}) do
    Assert.condition(
      is_number(lat) and abs(lat) <= 90,
      "the latitude #{inspect(lat)} is on the globe"
    )

    Assert.condition(
      is_number(lon) and abs(lon) <= 180,
      "the longitude #{inspect(lon)} is on the globe"
    )
  end

  defp box_tiles(%{from: from, to: to, plane: plane}, index, limits) do
    margin_lat = limits.margin_meters / plane.meters_per_lat
    margin_lon = limits.margin_meters / plane.meters_per_lon

    low =
      tile_of_units(
        floor((min(from.lat, to.lat) - margin_lat) * @units_per_degree),
        floor((min(from.lon, to.lon) - margin_lon) * @units_per_degree)
      )

    high =
      tile_of_units(
        ceil((max(from.lat, to.lat) + margin_lat) * @units_per_degree),
        ceil((max(from.lon, to.lon) + margin_lon) * @units_per_degree)
      )

    {low_row, low_column} = low
    {high_row, high_column} = high
    tile_count = (high_row - low_row + 1) * (high_column - low_column + 1)

    if tile_count > limits.tile_count_max do
      :too_far
    else
      tiles =
        for row <- low_row..high_row,
            column <- low_column..high_column,
            MapSet.member?(index, {row, column}),
            do: {row, column}

      {:tiles, tiles}
    end
  end

  defp tile_of_units(lat_units, lon_units),
    do: Tiles.tile_of({lat_units, lon_units}, Tiles.sizes())

  defp plan_path(%{from: from, to: to, pieces: pieces, limits: limits}) do
    plane = Graph.plane(from, to)
    graph = Graph.build(pieces, plane)
    start_snaps = Graph.snaps(graph, Graph.to_plane(plane, from), limits.snap_meters_max)
    goal_snaps = Graph.snaps(graph, Graph.to_plane(plane, to), limits.snap_meters_max)

    case Graph.choose(start_snaps, goal_snaps) do
      {:none, reason} ->
        {:no_path, reason}

      {:chosen, start, goal} ->
        case astar(graph, %{start: start, goal: goal, visited_max: limits.visited_node_count_max}) do
          {:reached, cost} -> {:found, cost + start.distance + goal.distance}
          :exhausted -> {:no_path, :disconnected}
          :capped -> {:no_path, :cap_reached}
        end
    end
  end

  # A* from the start snap to the goal snap, each a virtual node joining the
  # two ends of its edge. The loop settles one node a pass, and the visited
  # bound ends it.
  defp astar(graph, %{start: start, goal: goal, visited_max: visited_max}) do
    goal_edge = elem(graph.edges, goal.edge)
    context = %{graph: graph, start: start, goal: goal, goal_edge: goal_edge}
    heap = :gb_sets.singleton({heuristic(context, :start), 0, :start})
    state = %{heap: heap, costs: %{start: 0.0}, settled: MapSet.new(), counter: 1, visited: 0}
    astar_loop(state, context, visited_max)
  end

  defp astar_loop(%{heap: heap} = state, context, visited_max) do
    if :gb_sets.is_empty(heap) do
      :exhausted
    else
      {{_priority, _order, node}, rest} = :gb_sets.take_smallest(heap)
      settle(node, %{state | heap: rest}, context, visited_max)
    end
  end

  defp settle(node, state, context, visited_max) do
    cond do
      MapSet.member?(state.settled, node) -> astar_loop(state, context, visited_max)
      node == :goal -> {:reached, Map.fetch!(state.costs, :goal)}
      state.visited + 1 > visited_max -> :capped
      true -> state |> expand(node, context) |> astar_loop(context, visited_max)
    end
  end

  defp expand(state, node, context) do
    state = %{state | settled: MapSet.put(state.settled, node), visited: state.visited + 1}

    node
    |> steps(context)
    |> Enum.reduce(state, fn {to, meters}, current ->
      relax(current, node, {to, meters}, context)
    end)
  end

  defp relax(state, from, {to, meters}, context) do
    candidate = Map.fetch!(state.costs, from) + meters

    case state.costs do
      %{^to => held} when held <= candidate ->
        state

      _longer ->
        entry = {candidate + heuristic(context, to), state.counter, to}

        %{
          state
          | costs: Map.put(state.costs, to, candidate),
            heap: :gb_sets.add(entry, state.heap),
            counter: state.counter + 1
        }
    end
  end

  # The nodes a node leads to, with the meters to each: the start snap leads
  # to both ends of its edge, and to the goal when both are on one edge; a
  # node leads along each of its edges, and to the goal from either end of
  # the goal's edge.
  defp steps(:start, %{graph: graph, start: start, goal: goal}) do
    edge = elem(graph.edges, start.edge)
    ends = [{edge.a, start.along}, {edge.b, edge.length - start.along}]

    if start.edge == goal.edge do
      [{:goal, abs(goal.along - start.along)} | ends]
    else
      ends
    end
  end

  defp steps(node, %{graph: graph, goal: goal, goal_edge: goal_edge}) when is_integer(node) do
    along_edges =
      for index <- Map.fetch!(graph.node_edges, node) do
        edge = elem(graph.edges, index)
        {other_end(edge, node), edge.length}
      end

    along_edges ++ goal_steps(node, goal, goal_edge)
  end

  defp goal_steps(node, goal, goal_edge) do
    from_a = if node == goal_edge.a, do: [{:goal, goal.along}], else: []
    from_b = if node == goal_edge.b, do: [{:goal, goal_edge.length - goal.along}], else: []
    from_a ++ from_b
  end

  defp other_end(%{a: node, b: other}, node), do: other
  defp other_end(%{a: other}, _node), do: other

  defp heuristic(_context, :goal), do: 0.0
  defp heuristic(%{goal: goal, start: start}, :start), do: distance_to(start, goal)

  defp heuristic(%{graph: graph, goal: goal}, node) do
    distance_to(Map.fetch!(graph.node_xy, node), goal)
  end

  defp distance_to(%{x: x, y: y}, %{x: goal_x, y: goal_y}) do
    :math.sqrt(:math.pow(x - goal_x, 2) + :math.pow(y - goal_y, 2))
  end

  defp distance_to({x, y}, %{x: goal_x, y: goal_y}) do
    :math.sqrt(:math.pow(x - goal_x, 2) + :math.pow(y - goal_y, 2))
  end

  defp reach_targets(%{from: from, targets: targets, pieces: pieces, limits: limits}) do
    plane = Graph.plane(from, from)
    graph = Graph.build(pieces, plane)
    start_snaps = Graph.snaps(graph, Graph.to_plane(plane, from), limits.snap_meters_max)
    search = dijkstra(graph, start_snaps, limits)

    for target <- targets do
      goal_snaps = Graph.snaps(graph, Graph.to_plane(plane, target), limits.snap_meters_max)
      answer_target(graph, {start_snaps, goal_snaps}, search, limits)
    end
  end

  defp answer_target(graph, {start_snaps, goal_snaps}, search, limits) do
    case Graph.choose(start_snaps, goal_snaps) do
      {:none, reason} ->
        {:no_path, reason}

      {:chosen, _start, _goal} when search.status == :capped ->
        {:no_path, :cap_reached}

      {:chosen, start, goal} ->
        classify(street_meters(graph, {start, goal}, search.settled), {start, goal}, limits)
    end
  end

  defp classify(:infinity, _snaps, _limits), do: {:no_path, :beyond_bound}

  defp classify(street, {start, goal}, limits) do
    meters = street + start.distance + goal.distance

    if meters <= limits.street_meters_max do
      {:found, meters}
    else
      {:no_path, :beyond_bound}
    end
  end

  # The street meters from the start snap to the goal snap: along their one
  # edge, or out of the start by an end of its edge, through the settled
  # nodes, and into the goal by an end of its edge. A node the search did not
  # settle stands too far, and gives infinity.
  defp street_meters(graph, {start, goal}, settled) do
    goal_edge = elem(graph.edges, goal.edge)
    through_a = Map.get(settled, goal_edge.a, :infinity)
    through_b = Map.get(settled, goal_edge.b, :infinity)

    [
      sum(through_a, goal.along),
      sum(through_b, goal_edge.length - goal.along),
      same_edge_meters(start, goal)
    ]
    |> Enum.min()
  end

  defp sum(:infinity, _meters), do: :infinity
  defp sum(cost, meters), do: cost + meters

  defp same_edge_meters(%{edge: edge, along: start_along}, %{edge: edge, along: goal_along}) do
    abs(goal_along - start_along)
  end

  defp same_edge_meters(_start, _goal), do: :infinity

  # A multi-source Dijkstra from every snap of the start, one per component,
  # so the components stay apart, settling nodes in order of cost up to the
  # street bound and the visited bound. `settled` maps each settled node to
  # its cost.
  defp dijkstra(graph, start_snaps, limits) do
    heap =
      Enum.reduce(start_snaps, :gb_sets.empty(), fn {_component, snap}, heap ->
        edge = elem(graph.edges, snap.edge)
        heap = :gb_sets.add({snap.along, 0, edge.a}, heap)
        :gb_sets.add({edge.length - snap.along, 1, edge.b}, heap)
      end)

    state = %{heap: heap, settled: %{}, counter: 2}
    dijkstra_loop(state, graph, limits)
  end

  defp dijkstra_loop(%{heap: heap} = state, graph, limits) do
    if :gb_sets.is_empty(heap) do
      %{settled: state.settled, status: :done}
    else
      {{cost, _order, node}, rest} = :gb_sets.take_smallest(heap)
      settle_node({cost, node}, %{state | heap: rest}, graph, limits)
    end
  end

  defp settle_node({cost, node}, state, graph, limits) do
    cond do
      Map.has_key?(state.settled, node) ->
        dijkstra_loop(state, graph, limits)

      cost > limits.street_meters_max ->
        %{settled: state.settled, status: :done}

      map_size(state.settled) >= limits.visited_node_count_max ->
        %{settled: state.settled, status: :capped}

      true ->
        state |> reach_from(node, cost, graph) |> dijkstra_loop(graph, limits)
    end
  end

  defp reach_from(state, node, cost, graph) do
    settled = Map.put(state.settled, node, cost)

    Enum.reduce(Map.fetch!(graph.node_edges, node), %{state | settled: settled}, fn index,
                                                                                    current ->
      edge = elem(graph.edges, index)
      entry = {cost + edge.length, current.counter, other_end(edge, node)}
      %{current | heap: :gb_sets.add(entry, current.heap), counter: current.counter + 1}
    end)
  end
end
