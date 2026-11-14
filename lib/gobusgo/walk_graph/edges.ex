defmodule Gobusgo.WalkGraph.Edges do
  @points_max 1_000

  @moduledoc """
  Cuts a way into the edges a graph is made of. Everything here is pure.

  A vertex is `{lat, lon, junction?}` in the graph's units, `junction?` saying
  that another way, or the way's own end, meets the way at that node. An edge
  runs between two junctions along the way's vertices, and the first and
  last vertex of a way always end an edge. A vertex at the position of the
  one before it is dropped, an edge of fewer than two positions is dropped,
  and an edge of more than #{@points_max} positions is cut at a vertex into
  edges that share it, so an edge's count fits the 16 bits the shard stores.
  """

  @type vertex :: {integer(), integer(), boolean()}
  @type point :: {integer(), integer()}

  @doc "The most positions an edge holds."
  @spec points_max() :: pos_integer()
  def points_max, do: @points_max

  @doc "The edges of the way with `vertices`, each a list of at least two positions."
  @spec cut([vertex()]) :: [[point(), ...]]
  def cut(vertices) when is_list(vertices) do
    vertices
    |> dedupe()
    |> mark_ends()
    |> split_at_junctions([], [])
    |> Enum.flat_map(&split_long/1)
  end

  defp dedupe(vertices) do
    {kept, _last} =
      Enum.reduce(vertices, {[], nil}, fn {lat, lon, junction}, {kept, last} ->
        point = {lat, lon}

        case kept do
          [{_lat, _lon, previous} | rest] when last == point ->
            {[{lat, lon, previous or junction} | rest], point}

          _distinct ->
            {[{lat, lon, junction} | kept], point}
        end
      end)

    Enum.reverse(kept)
  end

  defp mark_ends([]), do: []
  defp mark_ends([{lat, lon, _flag}]), do: [{lat, lon, true}]

  defp mark_ends([{first_lat, first_lon, _first} | rest]) do
    {middle, [{last_lat, last_lon, _last}]} = Enum.split(rest, -1)
    [{first_lat, first_lon, true}] ++ middle ++ [{last_lat, last_lon, true}]
  end

  defp split_at_junctions([], _current, edges), do: Enum.reverse(edges)

  defp split_at_junctions([{lat, lon, junction} | rest], current, edges) do
    current = [{lat, lon} | current]
    has_edge = match?([_second, _first | _more], current)

    if junction and has_edge do
      split_at_junctions(rest, [{lat, lon}], [Enum.reverse(current) | edges])
    else
      split_at_junctions(rest, current, edges)
    end
  end

  defp split_long(edge) when length(edge) <= @points_max, do: [edge]

  defp split_long(edge) do
    {head, tail} = Enum.split(edge, @points_max)
    [shared | _earlier] = Enum.reverse(head)
    [head | split_long([shared | tail])]
  end
end
