defmodule Gobusgo.Routing.Transfers do
  @minimum_transfer_s 120
  @walk_radius_m 400
  @walk_speed_mm_per_s 1_200
  @degree_m 111_195
  @link_count_per_stop_max 64

  @moduledoc """
  The transfers of a snapshot, derived because `schedule-for-route` carries
  none (decided in GOB-237). Everything here is pure.

  A change of trip at one stop takes at least #{@minimum_transfer_s}
  seconds, which the manifest states and the snapshot holds no record of. A
  walking link joins two stops at most #{@walk_radius_m} m apart in a
  straight line, in both directions, and takes the distance at
  #{@walk_speed_mm_per_s / 1_000} m/s, rounded up to the second. A stop keeps
  its #{@link_count_per_stop_max} nearest links. The constants travel with
  the format version: a change to one is a change to the snapshot.

  Stops are bucketed into cells at least the walking radius on a side, so a
  stop is compared with the stops of its own cell and the eight around it.
  The cells share one longitude scale, that of the highest latitude among
  the stops, where a degree of longitude is shortest.
  """

  alias Gobusgo.Math.Geodesy
  alias Gobusgo.Routing.SnapshotFormat

  @type position :: %{lat: number(), lon: number()}

  @doc "The constants a reader needs to apply the transfers, as the manifest states them."
  @spec rules() :: %{
          minimum_transfer_s: pos_integer(),
          walk_radius_m: pos_integer(),
          walk_speed_m_per_s: float(),
          link_count_per_stop_max: pos_integer()
        }
  def rules do
    %{
      minimum_transfer_s: @minimum_transfer_s,
      walk_radius_m: @walk_radius_m,
      walk_speed_m_per_s: @walk_speed_mm_per_s / 1_000,
      link_count_per_stop_max: @link_count_per_stop_max
    }
  end

  @doc """
  Returns the walking links between the stops of `stop_ids`, indexed by
  their position in it, from `positions`, the position of each stop by
  identifier. A stop without a position has no link. The links are ordered
  by the stop they leave, then the one they reach.
  """
  @spec walking_links([String.t()], %{String.t() => position()}) :: [SnapshotFormat.transfer()]
  def walking_links(stop_ids, positions) when is_list(stop_ids) and is_map(positions) do
    located =
      for {stop_id, index} <- Enum.with_index(stop_ids),
          %{lat: lat, lon: lon} <- [Map.get(positions, stop_id)],
          do: %{index: index, lat: lat, lon: lon}

    lon_m = lon_m(located)
    cells = Enum.group_by(located, &cell(&1, lon_m))

    located
    |> Enum.flat_map(&links_from(&1, %{cells: cells, lon_m: lon_m}))
    |> Enum.sort_by(&{&1.from_stop, &1.to_stop})
  end

  defp links_from(stop, %{cells: cells, lon_m: lon_m}) do
    {row, column} = cell(stop, lon_m)

    neighbors =
      for row_step <- -1..1,
          column_step <- -1..1,
          neighbor <- Map.get(cells, {row + row_step, column + column_step}, []),
          neighbor.index != stop.index,
          distance_m = Geodesy.distance_meters(stop, neighbor),
          distance_m <= @walk_radius_m,
          do: {distance_m, neighbor.index}

    neighbors
    |> Enum.sort()
    |> Enum.take(@link_count_per_stop_max)
    |> Enum.map(fn {distance_m, to_stop} ->
      %{from_stop: stop.index, to_stop: to_stop, duration_s: duration_s(distance_m)}
    end)
  end

  defp cell(%{lat: lat, lon: lon}, lon_m) do
    {floor(lat * @degree_m / @walk_radius_m), floor(lon * lon_m / @walk_radius_m)}
  end

  # The meters of a degree of longitude at the highest latitude among the
  # stops, the shortest that any of them has.
  defp lon_m([]), do: @degree_m

  defp lon_m(located) do
    lat_max = located |> Enum.map(&abs(&1.lat)) |> Enum.max()
    @degree_m * max(:math.cos(Geodesy.radians(lat_max)), 0.01)
  end

  defp duration_s(distance_m), do: ceil(distance_m * 1_000 / @walk_speed_mm_per_s)
end
