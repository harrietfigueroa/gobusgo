defmodule Gobusgo.Places.Merge do
  @distance_m_max 150
  @distance_building_m_max 300

  @moduledoc """
  Merges the candidates that name one place twice, and orders what is left.
  Everything here is pure.

  Candidates are taken in descending prominence plus area score, ties broken by name and
  then position, so the result does not depend on input order. A candidate
  whose normalized name (`Gobusgo.Places.Words`) equals that of a place
  already kept, and that stands under #{@distance_m_max} m from it, or under #{@distance_building_m_max} m
  when either is a building, is merged into that place: the
  kept place gains its aliases. The places are then ordered by category, in
  the order of `Gobusgo.Places.Classification.categories/0`, then by name,
  which groups like text for compression.
  """

  alias Gobusgo.Math.Geodesy
  alias Gobusgo.Places.Classification
  alias Gobusgo.Places.Selection
  alias Gobusgo.Places.Words

  @building_category "building"

  @type result :: %{places: [Selection.candidate()], merged_count: non_neg_integer()}

  @doc "Merges `candidates` and orders the places that remain."
  @spec run([Selection.candidate()]) :: result()
  def run(candidates) when is_list(candidates) do
    ordered = Enum.sort_by(candidates, &{-significance(&1), &1.name, &1.lat, &1.lon})

    {by_key, merged_count} =
      Enum.reduce(ordered, {%{}, 0}, fn candidate, {by_key, merged_count} ->
        key = Words.key(candidate.name)
        kept = Map.get(by_key, key, [])

        case merge_into(kept, candidate) do
          {:merged, kept} -> {Map.put(by_key, key, kept), merged_count + 1}
          :distinct -> {Map.put(by_key, key, kept ++ [candidate]), merged_count}
        end
      end)

    categories = Classification.categories()
    places = by_key |> Map.values() |> List.flatten()

    sorted =
      Enum.sort_by(places, fn place ->
        {Enum.find_index(categories, &(&1 == place.category)), place.name, place.lat, place.lon}
      end)

    %{places: sorted, merged_count: merged_count}
  end

  # What a merge keeps first: the prominence and the area score together,
  # which the file stores apart.
  defp significance(%{prominence: prominence, area_score: area_score}),
    do: prominence + area_score

  # The first kept place the candidate duplicates takes its aliases.
  defp merge_into(kept, candidate) do
    case Enum.find_index(kept, &duplicate?(&1, candidate)) do
      nil -> :distinct
      index -> {:merged, List.update_at(kept, index, &absorb(&1, candidate))}
    end
  end

  defp duplicate?(place, candidate) do
    building = @building_category in [place.category, candidate.category]
    limit = if building, do: @distance_building_m_max, else: @distance_m_max
    Geodesy.distance_meters(place, candidate) < limit
  end

  defp absorb(place, candidate) do
    added = Enum.reject(candidate.aliases, &(&1 == place.name or &1 in place.aliases))
    %{place | aliases: place.aliases ++ added}
  end
end
