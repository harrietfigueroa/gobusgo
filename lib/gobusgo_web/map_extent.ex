defmodule GobusgoWeb.MapExtent do
  @span_degrees_min 0.01

  @moduledoc """
  The bounds a map fits to show a set of positions: the box around them,
  inside the bounds the map can draw. Everything here is pure.

  A box that is shorter than #{@span_degrees_min} degrees on a side is
  widened to that span around its middle on that side, so one position, and
  positions in one line, give a view of their surroundings. The box ends
  where the bounds it has to lie within end. No position, and positions
  whose box lies outside those bounds, give no bounds.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Basemap.Manifest

  @type position :: %{lat: number(), lon: number()}

  @doc "The shortest side of the bounds `bounds/1` returns, in degrees."
  @spec span_degrees_min() :: float()
  def span_degrees_min, do: @span_degrees_min

  @doc """
  Returns the bounds that show `positions` inside `within`, or `nil` when
  there is no position or none of the box lies inside `within`.
  """
  @spec bounds(%{positions: [position()], within: Manifest.bounds()}) :: Manifest.bounds() | nil
  def bounds(%{positions: [], within: _within}), do: nil

  def bounds(%{positions: [_position | _rest] = positions, within: within}) do
    Assert.condition(within.south < within.north, "within must span latitudes")
    Assert.condition(within.west < within.east, "within must span longitudes")

    {south, north} = positions |> Enum.map(&latitude/1) |> Enum.min_max() |> widened()
    {west, east} = positions |> Enum.map(&longitude/1) |> Enum.min_max() |> widened()

    box = %{
      south: max(south, within.south),
      west: max(west, within.west),
      north: min(north, within.north),
      east: min(east, within.east)
    }

    case {box.south < box.north, box.west < box.east} do
      {true, true} -> box
      {_spans_latitudes, _spans_longitudes} -> nil
    end
  end

  defp latitude(%{lat: lat}) when is_number(lat), do: lat
  defp longitude(%{lon: lon}) when is_number(lon), do: lon

  # A side that already spans the shortest span is returned as it is, so
  # the edges of such a box are positions' own coordinates.
  defp widened({low, high}) do
    if high - low >= @span_degrees_min do
      {low, high}
    else
      middle = (low + high) / 2
      {middle - @span_degrees_min / 2, middle + @span_degrees_min / 2}
    end
  end
end
