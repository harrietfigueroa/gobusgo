defmodule Gobusgo.WalkGraph.Graph do
  @moduledoc """
  The graph over the pieces of some shards, and the snaps of a point onto
  it. Everything here is pure.

  A node is a position that ends a piece, and pieces that end at one
  position, in one shard or two, meet there. An edge is one piece, its
  segments laid on a plane tangent at a reference position, so a length is
  in meters. Each node belongs to a connected component, the set of nodes a
  walk can reach from it.

  A point snaps to the nearest point of each component within a bound. Two
  distances that agree to a micrometer tie, and a tie goes to the lesser x,
  then the lesser y, then the lesser ends of the edge, then the lesser start
  of the segment, so no choice rests on the order the pieces arrived in; the
  pair of snaps for two points is chosen the same way (`choose/2`). The
  segments are held in a grid of square cells, so a snap reads only the
  segments near the point.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Math.Geodesy
  alias Gobusgo.WalkGraph.Format

  @tie_units_per_meter 1_000_000
  @cell_meters 100
  @units_per_degree Format.units_per_degree()

  @type position :: %{lat: number(), lon: number()}
  @type plane :: %{
          reference_lat: float(),
          reference_lon: float(),
          meters_per_lat: float(),
          meters_per_lon: float()
        }
  @type snap :: %{
          edge: non_neg_integer(),
          x: float(),
          y: float(),
          distance: float(),
          along: float(),
          ends: {{integer(), integer()}, {integer(), integer()}},
          key: tuple()
        }
  @type t :: %{
          edges: tuple(),
          node_edges: %{non_neg_integer() => [non_neg_integer()]},
          node_xy: %{non_neg_integer() => {float(), float()}},
          node_components: %{non_neg_integer() => non_neg_integer()},
          cells: %{{integer(), integer()} => [{non_neg_integer(), map()}]}
        }

  @doc "The plane tangent at the middle of `from` and `to`, whose latitude and longitude are in degrees."
  @spec plane(position(), position()) :: plane()
  def plane(%{lat: from_lat, lon: from_lon}, %{lat: to_lat, lon: to_lon}) do
    reference_lat = (from_lat + to_lat) / 2
    reference_lon = (from_lon + to_lon) / 2

    Assert.condition(
      abs(reference_lat) <= 90,
      "the plane's latitude #{reference_lat} is on the globe"
    )

    %{
      reference_lat: reference_lat,
      reference_lon: reference_lon,
      meters_per_lat: Geodesy.meters_per_degree(),
      meters_per_lon: Geodesy.meters_per_degree() * :math.cos(Geodesy.radians(reference_lat))
    }
  end

  @doc "A position in degrees as meters east and north on `plane`."
  @spec to_plane(plane(), position()) :: {float(), float()}
  def to_plane(plane, %{lat: lat, lon: lon}) do
    {(lon - plane.reference_lon) * plane.meters_per_lon,
     (lat - plane.reference_lat) * plane.meters_per_lat}
  end

  @doc """
  The graph over `pieces`, each `%{points: [{latitude, longitude}, ...]}` in
  the graph's units, on `plane`.
  """
  @spec build([Format.piece()], plane()) :: t()
  def build(pieces, plane) when is_list(pieces) do
    {edges, node_by_point, _count} =
      Enum.reduce(pieces, {[], %{}, 0}, fn piece, {edges, nodes, count} ->
        {edge, nodes} = edge_of(piece, plane, nodes)
        {[edge | edges], nodes, count + 1}
      end)

    edges = Enum.reverse(edges)
    node_xy = node_positions(node_by_point, plane)
    node_edges = adjacency(edges)
    components = components(node_edges, edges)

    labeled =
      for edge <- edges, do: Map.put(edge, :component, Map.fetch!(components, edge.a))

    %{
      edges: List.to_tuple(labeled),
      node_edges: node_edges,
      node_xy: node_xy,
      node_components: components,
      cells: cells_of(labeled)
    }
  end

  @doc "The number of edges of `graph`."
  @spec edge_count(t()) :: non_neg_integer()
  def edge_count(%{edges: edges}), do: tuple_size(edges)

  @doc """
  The nearest point of each component within `snap_meters_max` of `point`, a
  position on the plane: a map from the component to its snap. A component
  with no edge that near is left out.
  """
  @spec snaps(t(), {float(), float()}, number()) :: %{non_neg_integer() => snap()}
  def snaps(%{edges: edges, cells: cells}, {x, y}, snap_meters_max) do
    Assert.condition(snap_meters_max > 0, "the snap bound #{snap_meters_max} is positive")

    candidates =
      for cell_x <- cell_of(x - snap_meters_max)..cell_of(x + snap_meters_max),
          cell_y <- cell_of(y - snap_meters_max)..cell_of(y + snap_meters_max),
          entry <- Map.get(cells, {cell_x, cell_y}, []),
          do: entry

    Enum.reduce(candidates, %{}, fn {index, segment}, held ->
      edge = elem(edges, index)
      keep_nearer(held, {index, edge}, nearest(segment, x, y), snap_meters_max)
    end)
  end

  @doc """
  The pair of snaps, `{:chosen, start, goal}`, in a component both reach
  whose distances sum least, or `{:none, reason}`: `:off_graph` where an end
  reaches no component and `:disconnected` where the two reach none in
  common. Sums within a micrometer tie, and the tie goes to the start snap
  nearer its end, then to the lesser positions.
  """
  @spec choose(%{non_neg_integer() => snap()}, %{non_neg_integer() => snap()}) ::
          {:chosen, snap(), snap()} | {:none, :off_graph | :disconnected}
  def choose(start_snaps, goal_snaps) do
    shared =
      Enum.filter(start_snaps, fn {component, _start} -> Map.has_key?(goal_snaps, component) end)

    pairs =
      Enum.map(shared, fn {component, start} -> {start, Map.fetch!(goal_snaps, component)} end)

    cond do
      map_size(start_snaps) == 0 or map_size(goal_snaps) == 0 ->
        {:none, :off_graph}

      pairs == [] ->
        {:none, :disconnected}

      true ->
        pairs |> Enum.min_by(&pair_key/1) |> then(fn {start, goal} -> {:chosen, start, goal} end)
    end
  end

  # An edge from one piece: its nodes, its segments on the plane with the
  # distance along the edge at each segment's start, and its length.
  defp edge_of(%{points: points}, plane, nodes) do
    Assert.condition(
      match?([_first, _second | _rest], points),
      "a piece has at least two positions"
    )

    xy = for {lat, lon} <- points, do: units_to_plane(plane, lat, lon)
    {segments, length} = segments_of(xy)
    {a, nodes} = node_at(nodes, List.first(points))
    {b, nodes} = node_at(nodes, List.last(points))
    Assert.condition(a != b, "a piece starts and ends at one node")
    ends = ends_of(List.first(points), List.last(points))
    {%{a: a, b: b, segments: segments, length: length, ends: ends}, nodes}
  end

  defp units_to_plane(plane, lat_units, lon_units) do
    to_plane(plane, %{lat: lat_units / @units_per_degree, lon: lon_units / @units_per_degree})
  end

  defp segments_of([first | rest]) do
    {segments, _last, length} =
      Enum.reduce(rest, {[], first, 0.0}, fn point, {segments, previous, along} ->
        {previous_x, previous_y} = previous
        {x, y} = point
        segment_length = distance_of(x - previous_x, y - previous_y)
        segment = %{start: previous, stop: point, along: along, length: segment_length}
        {[segment | segments], point, along + segment_length}
      end)

    {Enum.reverse(segments), length}
  end

  # The two ends of an edge, the lesser first, so one piece has one pair of
  # ends whichever way it is walked.
  defp ends_of(first, last) when first <= last, do: {first, last}
  defp ends_of(first, last), do: {last, first}

  defp distance_of(delta_x, delta_y), do: :math.sqrt(delta_x * delta_x + delta_y * delta_y)

  # The segments of every edge in a grid of square cells: each segment is in
  # every cell its box touches, so the cells a point's bound touches hold
  # every segment within that bound.
  defp cells_of(edges) do
    edges
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {edge, index}, cells ->
      Enum.reduce(edge.segments, cells, fn segment, held ->
        {start_x, start_y} = segment.start
        {stop_x, stop_y} = segment.stop

        for cell_x <- cell_of(min(start_x, stop_x))..cell_of(max(start_x, stop_x)),
            cell_y <- cell_of(min(start_y, stop_y))..cell_of(max(start_y, stop_y)),
            reduce: held do
          acc -> Map.update(acc, {cell_x, cell_y}, [{index, segment}], &[{index, segment} | &1])
        end
      end)
    end)
  end

  defp cell_of(meters), do: floor(meters / @cell_meters)

  defp node_at(nodes, point) do
    case Map.fetch(nodes, point) do
      {:ok, node} ->
        {node, nodes}

      :error ->
        node = map_size(nodes)
        {node, Map.put(nodes, point, node)}
    end
  end

  defp node_positions(node_by_point, plane) do
    Map.new(node_by_point, fn {{lat, lon}, node} -> {node, units_to_plane(plane, lat, lon)} end)
  end

  defp adjacency(edges) do
    edges
    |> Enum.with_index()
    |> Enum.reduce(%{}, fn {edge, index}, node_edges ->
      node_edges
      |> Map.update(edge.a, [index], &[index | &1])
      |> Map.update(edge.b, [index], &[index | &1])
    end)
  end

  # The component of each node: the lowest node reachable from it, found by
  # a walk that visits each node once, so it ends after the node count.
  defp components(node_edges, edges) do
    edge_tuple = List.to_tuple(edges)
    nodes = node_edges |> Map.keys() |> Enum.sort()

    Enum.reduce(nodes, %{}, fn node, labeled ->
      case labeled do
        %{^node => _component} -> labeled
        _unlabeled -> flood([node], node, labeled, %{node_edges: node_edges, edges: edge_tuple})
      end
    end)
  end

  defp flood([], _component, labeled, _graph), do: labeled

  defp flood([node | stack], component, labeled, graph) do
    case labeled do
      %{^node => _component} ->
        flood(stack, component, labeled, graph)

      _unlabeled ->
        neighbors =
          for index <- Map.fetch!(graph.node_edges, node),
              edge = elem(graph.edges, index),
              do: other_end(edge, node)

        flood(neighbors ++ stack, component, Map.put(labeled, node, component), graph)
    end
  end

  defp other_end(%{a: node, b: other}, node), do: other
  defp other_end(%{a: other}, _node), do: other

  defp nearest(segment, x, y) do
    {start_x, start_y} = segment.start
    {stop_x, stop_y} = segment.stop
    delta_x = stop_x - start_x
    delta_y = stop_y - start_y
    length_squared = delta_x * delta_x + delta_y * delta_y
    fraction = fraction_along(length_squared, {x - start_x, y - start_y}, {delta_x, delta_y})
    point_x = start_x + fraction * delta_x
    point_y = start_y + fraction * delta_y

    %{
      x: point_x,
      y: point_y,
      distance: distance_of(x - point_x, y - point_y),
      along: segment.along + fraction * :math.sqrt(length_squared),
      segment_start: segment.start
    }
  end

  defp fraction_along(length_squared, _offset, _delta) when length_squared <= 0, do: 0.0

  defp fraction_along(length_squared, {offset_x, offset_y}, {delta_x, delta_y}) do
    ((offset_x * delta_x + offset_y * delta_y) / length_squared) |> max(0.0) |> min(1.0)
  end

  defp keep_nearer(held, {index, edge}, nearest, snap_meters_max) do
    {segment_x, segment_y} = nearest.segment_start

    candidate = %{
      edge: index,
      x: nearest.x,
      y: nearest.y,
      distance: nearest.distance,
      along: nearest.along,
      ends: edge.ends,
      key: {tie_units(nearest.distance), nearest.x, nearest.y, edge.ends, segment_x, segment_y}
    }

    is_near = nearest.distance <= snap_meters_max
    current = Map.get(held, edge.component)
    is_closer = is_near and (current == nil or candidate.key < current.key)

    if is_closer do
      Map.put(held, edge.component, candidate)
    else
      held
    end
  end

  defp tie_units(meters), do: round(meters * @tie_units_per_meter)

  defp pair_key({start, goal}) do
    {tie_units(start.distance + goal.distance), tie_units(start.distance), start.x, start.y,
     goal.x, goal.y, start.ends, goal.ends}
  end
end
