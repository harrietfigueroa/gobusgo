defmodule Gobusgo.Places.Locality do
  @length_max 80
  @nearest_radius_m_max 3_000
  @city_radius_m_max 20_000
  @nearest_cell_degrees 0.05
  @city_cell_degrees 0.3
  @neighborhood_kinds ~w(neighbourhood suburb quarter)
  @city_kinds ~w(town city)
  @settlement_category "place"
  @control_or_semicolon ~r/[\x00-\x1f;]/

  @moduledoc """
  The locality of a place, the words that tell two places of one name apart:
  its own street address where OpenStreetMap tags both `addr:housenumber`
  and `addr:street`, otherwise the name of the nearest settlement. Everything
  here is pure.

  The settlements are the places of category `place` tagged `place=` one of
  #{Enum.join(@neighborhood_kinds ++ @city_kinds, ", ")}, taken before the merge so that a
  merge that keeps another feature of the same name loses none. The nearest
  settlement within #{@nearest_radius_m_max} m names the place, and a neighborhood, suburb,
  or quarter is followed by the nearest town or city within #{@city_radius_m_max} m when that
  city's name differs, as "Denny Triangle, Seattle". A settlement never names
  itself, so its own locality is its city. A locality is at most
  #{@length_max} characters, and a place with none has the empty string.

  A cell grid over the settlements keeps the search to the cells around a
  place: #{@nearest_cell_degrees} degrees is wider than #{@nearest_radius_m_max} m, and #{@city_cell_degrees} degrees wider than
  #{@city_radius_m_max} m, at the latitudes of Puget Sound.
  """

  alias Gobusgo.Math.Geodesy

  @type anchor :: %{name: String.t(), lat: float(), lon: float(), settlement: String.t()}
  @type anchors :: %{nearest: map(), cities: map()}

  @doc "The most characters a locality holds, at build and at read."
  @spec length_max() :: pos_integer()
  def length_max, do: @length_max

  @doc "The street address the tags of a feature hold, or the empty string."
  @spec address(%{optional(String.t()) => term()}) :: String.t()
  def address(tags) do
    number = text(Map.get(tags, "addr:housenumber"))
    street = text(Map.get(tags, "addr:street"))

    if number == "" or street == "", do: "", else: bound(number <> " " <> street)
  end

  @doc "Cuts a locality to `length_max/0` characters."
  @spec bound(String.t()) :: String.t()
  def bound(locality) do
    locality |> String.codepoints() |> Enum.take(@length_max) |> Enum.join()
  end

  @doc "The grids of the settlements among `candidates`."
  @spec anchors([map()]) :: anchors()
  def anchors(candidates) do
    settlements = Enum.filter(candidates, &settlement?/1)
    cities = Enum.filter(settlements, &(&1.settlement in @city_kinds))

    %{
      nearest: grid(settlements, @nearest_cell_degrees),
      cities: grid(cities, @city_cell_degrees)
    }
  end

  @doc "`places` with the `locality` each one gets from its address or `anchors`."
  @spec assign([map()], anchors()) :: [map()]
  def assign(places, anchors) do
    for place <- places, do: Map.put(place, :locality, locality(place, anchors))
  end

  defp locality(%{address: address}, _anchors) when address != "", do: bound(address)

  defp locality(%{category: @settlement_category, settlement: kind}, _anchors)
       when kind in @city_kinds, do: ""

  defp locality(place, anchors) do
    case nearest(place, anchors.nearest, @nearest_cell_degrees, @nearest_radius_m_max) do
      :none ->
        ""

      {:found, %{settlement: kind} = anchor} when kind in @city_kinds ->
        bound(anchor.name)

      {:found, anchor} ->
        with_city(place, anchor, anchors.cities)
    end
  end

  defp with_city(place, anchor, cities) do
    case nearest(anchor, cities, @city_cell_degrees, @city_radius_m_max) do
      {:found, %{name: name}} when name != anchor.name and name != place.name ->
        bound(anchor.name <> ", " <> name)

      _same_or_none ->
        bound(anchor.name)
    end
  end

  # The nearest anchor to `place` within `radius`, nearest first and then by
  # name, other than one that bears the place's own name.
  defp nearest(place, grid, cell, radius) do
    {row, column} = cell_of(place, cell)

    candidates =
      for row_offset <- -1..1,
          column_offset <- -1..1,
          anchor <- Map.get(grid, {row + row_offset, column + column_offset}, []),
          anchor.name != place.name,
          distance = Geodesy.distance_meters(place, anchor),
          distance <= radius,
          do: {distance, anchor.name, anchor}

    case Enum.min_by(candidates, fn {distance, name, _anchor} -> {distance, name} end, fn ->
           :none
         end) do
      :none -> :none
      {_distance, _name, anchor} -> {:found, anchor}
    end
  end

  defp grid(anchors, cell) do
    Enum.group_by(anchors, &cell_of(&1, cell))
  end

  defp cell_of(%{lat: lat, lon: lon}, cell), do: {floor(lat / cell), floor(lon / cell)}

  defp settlement?(candidate) do
    is_settlement = candidate.category == @settlement_category
    is_kind = candidate.settlement in @neighborhood_kinds or candidate.settlement in @city_kinds
    is_settlement and is_kind
  end

  defp text(value) when is_binary(value) do
    @control_or_semicolon |> Regex.replace(value, " ") |> String.trim()
  end

  defp text(_value), do: ""
end
