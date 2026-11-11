defmodule Gobusgo.Intersections.Merge do
  @radius_meters_max 150
  @microdegrees 1_000_000

  @moduledoc """
  Turns the nodes that roads share into intersections: one per pair of
  street keys and place. Every pair of the keys through a node is a crossing
  at that node, and the nodes of one pair that lie within
  #{@radius_meters_max} m of the mean of a group are one intersection, at
  the mean of their positions, so a dual carriageway or a roundabout that
  crosses a street at several nodes is one crossing. Nodes are taken in the
  order of their identifiers, so the groups do not depend on the order of
  the input. Everything here is pure.
  """

  alias Gobusgo.Math.Geodesy

  @type intersection :: %{
          first: String.t(),
          second: String.t(),
          lat_microdegrees: integer(),
          lon_microdegrees: integer()
        }

  @doc "The radius within which the nodes of a pair are one intersection, in meters."
  @spec radius_meters_max() :: pos_integer()
  def radius_meters_max, do: @radius_meters_max

  @doc """
  The intersections of `nodes`, each `%{id:, lat_microdegrees:,
  lon_microdegrees:, keys:}`, ordered by pair and position, with the count
  of the pairs.
  """
  @spec run([Gobusgo.Intersections.Selection.shared_node()]) :: %{
          intersections: [intersection()],
          pair_count: non_neg_integer()
        }
  def run(nodes) when is_list(nodes) do
    groups =
      nodes
      |> Enum.sort_by(& &1.id)
      |> Enum.reduce(%{}, &add_node/2)

    intersections =
      for {{first, second}, clusters} <- Enum.sort(groups),
          cluster <- Enum.sort_by(clusters, &{&1.lat, &1.lon}) do
        %{
          first: first,
          second: second,
          lat_microdegrees: round(cluster.lat),
          lon_microdegrees: round(cluster.lon)
        }
      end

    %{intersections: intersections, pair_count: map_size(groups)}
  end

  defp add_node(%{keys: keys} = node, groups) do
    point = %{lat: node.lat_microdegrees * 1.0, lon: node.lon_microdegrees * 1.0, count: 1}

    for first <- keys, second <- keys, first < second, reduce: groups do
      groups -> Map.update(groups, {first, second}, [point], &join(&1, point))
    end
  end

  defp join(clusters, point) do
    {near, others} = Enum.split_with(clusters, &near?(&1, point))

    case near do
      [] -> [point | others]
      [cluster | _rest] -> [mean(cluster, point) | others]
    end
  end

  defp near?(cluster, point) do
    from = %{lat: cluster.lat / @microdegrees, lon: cluster.lon / @microdegrees}
    to = %{lat: point.lat / @microdegrees, lon: point.lon / @microdegrees}
    Geodesy.distance_meters(from, to) <= @radius_meters_max
  end

  defp mean(cluster, point) do
    count = cluster.count + 1

    %{
      lat: (cluster.lat * cluster.count + point.lat) / count,
      lon: (cluster.lon * cluster.count + point.lon) / count,
      count: count
    }
  end
end
