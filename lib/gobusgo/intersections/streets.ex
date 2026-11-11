defmodule Gobusgo.Intersections.Streets do
  @moduledoc """
  Groups intersections by street: each crossing is stored under both
  streets' keys, so a search reads the shard of the first street typed
  whichever street that is. A street's crossings are ordered by position,
  then by the other street's key, which keeps the path of positions short.
  Streets are ordered by their shard key (`Gobusgo.Intersections.Names.name_key/1`),
  then by key, as `Gobusgo.Addresses.Shards.split/2` needs them. Everything
  here is pure.
  """

  alias Gobusgo.Intersections.Merge
  alias Gobusgo.Intersections.Names

  @type crossing :: %{
          other: String.t(),
          lat_microdegrees: integer(),
          lon_microdegrees: integer()
        }

  @type street :: %{key: String.t(), name_key: String.t(), crossings: [crossing(), ...]}

  @doc "The streets of `intersections`, with every crossing under both of its streets."
  @spec group([Merge.intersection()]) :: [street()]
  def group(intersections) when is_list(intersections) do
    by_key =
      Enum.reduce(intersections, %{}, fn intersection, by_key ->
        by_key
        |> add(intersection.first, crossing(intersection, intersection.second))
        |> add(intersection.second, crossing(intersection, intersection.first))
      end)

    streets =
      for {key, crossings} <- by_key do
        %{
          key: key,
          name_key: Names.name_key(key),
          crossings:
            Enum.sort_by(crossings, &{&1.lat_microdegrees, &1.lon_microdegrees, &1.other})
        }
      end

    Enum.sort_by(streets, &{&1.name_key, &1.key})
  end

  defp crossing(intersection, other) do
    %{
      other: other,
      lat_microdegrees: intersection.lat_microdegrees,
      lon_microdegrees: intersection.lon_microdegrees
    }
  end

  defp add(by_key, key, crossing), do: Map.update(by_key, key, [crossing], &[crossing | &1])
end
