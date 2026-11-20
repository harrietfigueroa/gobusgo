defmodule Gobusgo.WalkGraph.Simplify do
  @moduledoc """
  Drops the positions of an edge that lie within a tolerance of the line
  their neighbors make, by the Douglas-Peucker rule. Everything here is
  pure.

  A position is `{lat, lon}` in the graph's units
  (`Gobusgo.WalkGraph.Format.units_per_degree/0`). The distance of a position
  from a line is measured on a plane in which a unit of longitude is
  scaled by the cosine of the edge's first latitude, so the tolerance is the
  same length in both directions. The first and the last position are always
  kept, since they are the junctions the edge joins other edges at. The
  search keeps its pending ranges on an explicit stack of at most one entry
  per position, so it runs at most as many steps as the edge has positions.
  """

  alias Gobusgo.Assert

  @type point :: {integer(), integer()}

  @doc "The positions of `points` that stay, in order, for a tolerance of `tolerance` units."
  @spec run([point()], %{tolerance: number(), units_per_degree: pos_integer()}) :: [point()]
  def run(points, _options) when length(points) <= 2, do: points

  def run([{first_lat, _lon} | _rest] = points, %{
        tolerance: tolerance,
        units_per_degree: units_per_degree
      }) do
    scale = :math.cos(first_lat / units_per_degree * :math.pi() / 180)
    tuple = points |> Enum.map(fn {lat, lon} -> {lat * 1.0, lon * scale} end) |> List.to_tuple()
    last = tuple_size(tuple) - 1
    steps_max = 2 * tuple_size(tuple)

    kept =
      keep(%{tuple: tuple, tolerance: tolerance}, [{0, last}], MapSet.new([0, last]), steps_max)

    points
    |> Enum.with_index()
    |> Enum.filter(fn {_point, index} -> MapSet.member?(kept, index) end)
    |> Enum.map(&elem(&1, 0))
  end

  defp keep(_context, [], kept, _steps), do: kept

  defp keep(%{tuple: tuple, tolerance: tolerance} = context, [{low, high} | stack], kept, steps) do
    Assert.condition(steps > 0, "the search took more steps than twice the edge's positions")
    {farthest, distance} = farthest(tuple, low, high)

    if distance > tolerance do
      keep(
        context,
        [{low, farthest}, {farthest, high} | stack],
        MapSet.put(kept, farthest),
        steps - 1
      )
    else
      keep(context, stack, kept, steps - 1)
    end
  end

  defp farthest(_tuple, low, high) when high - low < 2, do: {low, 0.0}

  defp farthest(tuple, low, high) do
    start = elem(tuple, low)
    finish = elem(tuple, high)

    Enum.reduce((low + 1)..(high - 1), {low, -1.0}, fn index, {best, best_distance} ->
      distance = distance(elem(tuple, index), start, finish)
      if distance > best_distance, do: {index, distance}, else: {best, best_distance}
    end)
  end

  defp distance({x, y}, {start_x, start_y}, {finish_x, finish_y}) do
    delta_x = finish_x - start_x
    delta_y = finish_y - start_y
    length_squared = delta_x * delta_x + delta_y * delta_y

    if length_squared == 0.0 do
      :math.sqrt((x - start_x) * (x - start_x) + (y - start_y) * (y - start_y))
    else
      abs(delta_x * (start_y - y) - (start_x - x) * delta_y) / :math.sqrt(length_squared)
    end
  end
end
