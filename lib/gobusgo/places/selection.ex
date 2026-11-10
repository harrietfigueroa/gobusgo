defmodule Gobusgo.Places.Selection do
  @area_floor_m2 1_000

  @moduledoc """
  Turns the records of an `osmium export -f geojsonseq -a type,id` into the
  candidates of the places file: classifies each by
  `Gobusgo.Places.Classification`, positions it, cleans its name, and
  collects its aliases. Everything here is pure.

  Transit stops and platforms are left out before classification, whatever
  else a feature is tagged, since they come from the stop view; stations stay.

  A record is the text between two U+001E separators, decoded with the
  built-in `JSON`. A position is the point itself, or the area-weighted
  centroid of the outer rings of a polygon or multipolygon on a plane
  tangent at the first vertex, with the ring areas summed as the area in
  square meters.

  Prominence is the category's base plus 40 for `wikidata` plus 15 for
  `wikipedia`, at most 255. `area_score` is separate and never added to it:
  0 for a point or an area under #{@area_floor_m2} square meters, otherwise
  `min(40, round(8 * log10(area / 1000)))`.
  """

  alias Gobusgo.Math.Geodesy
  alias Gobusgo.Places.Bounds
  alias Gobusgo.Places.Classification

  @name_length_max 200
  @prominence_max 255
  @wikidata_bonus 40
  @wikipedia_bonus 15
  @area_score_max 40
  @area_score_per_decade 8
  @alias_keys ~w(alt_name short_name official_name old_name name:en loc_name)
  @control_or_semicolon ~r/[\x00-\x1f;]/

  @type candidate :: %{
          name: String.t(),
          aliases: [String.t()],
          lat: float(),
          lon: float(),
          category: String.t(),
          prominence: pos_integer(),
          area: float(),
          area_score: non_neg_integer()
        }
  @type skip :: :unnamed | :stop | :excluded | {:outside, String.t()} | :unusable
  @type counts :: %{
          read: non_neg_integer(),
          named: non_neg_integer(),
          stops: non_neg_integer(),
          excluded: non_neg_integer(),
          outside: non_neg_integer(),
          unusable: non_neg_integer(),
          kept: non_neg_integer(),
          by_category: %{
            optional(String.t()) => %{kept: non_neg_integer(), outside: non_neg_integer()}
          }
        }

  @doc """
  Selects the candidates of `records`, an enumerable of record texts, inside
  `bounds`, and counts what became of each record. Blank records are not
  counted.
  """
  @spec run(Enumerable.t(String.t()), Bounds.t()) :: {[candidate()], counts()}
  def run(records, bounds) do
    start =
      {[],
       %{
         read: 0,
         named: 0,
         stops: 0,
         excluded: 0,
         outside: 0,
         unusable: 0,
         kept: 0,
         by_category: %{}
       }}

    records
    |> Enum.reduce(start, fn record, {places, counts} ->
      case String.trim(record) do
        "" -> {places, counts}
        text -> tally(select(text, bounds), places, counts)
      end
    end)
  end

  @doc "Selects the candidate one record holds, or says why it holds none."
  @spec select(String.t(), Bounds.t()) :: {:place, candidate()} | {:skipped, skip()}
  def select(record, bounds) when is_binary(record) do
    case JSON.decode(record) do
      {:ok, %{"properties" => %{} = tags, "geometry" => %{} = geometry}} ->
        select_feature(tags, geometry, bounds)

      _undecodable ->
        {:skipped, :unusable}
    end
  end

  defp select_feature(tags, geometry, bounds) do
    name = clean(Map.get(tags, "name", ""))

    cond do
      not is_binary(Map.get(tags, "name")) or name == "" -> {:skipped, :unnamed}
      Classification.stop?(tags) -> {:skipped, :stop}
      true -> classify_feature(name, tags, geometry, bounds)
    end
  end

  defp classify_feature(name, tags, geometry, bounds) do
    case {Classification.classify(tags), position(geometry)} do
      {:excluded, _position} ->
        {:skipped, :excluded}

      {{:ok, _classification}, :unusable} ->
        {:skipped, :unusable}

      {{:ok, %{category: category, base: base}}, {:ok, position}} ->
        if Bounds.contains?(bounds, position) do
          {:place,
           candidate(%{
             name: name,
             tags: tags,
             category: category,
             base: base,
             position: position
           })}
        else
          {:skipped, {:outside, category}}
        end
    end
  end

  defp candidate(%{name: name, tags: tags, category: category, base: base, position: position}) do
    %{
      name: name,
      aliases: aliases(tags, name),
      lat: position.lat,
      lon: position.lon,
      category: category,
      prominence: prominence(tags, base),
      area: position.area,
      area_score: area_score(position.area)
    }
  end

  defp prominence(tags, base) do
    wikidata = if Map.has_key?(tags, "wikidata"), do: @wikidata_bonus, else: 0
    wikipedia = if Map.has_key?(tags, "wikipedia"), do: @wikipedia_bonus, else: 0
    min(@prominence_max, base + wikidata + wikipedia)
  end

  defp area_score(area) when area < @area_floor_m2, do: 0

  defp area_score(area) do
    decades = :math.log10(area / @area_floor_m2)
    min(@area_score_max, round(@area_score_per_decade * decades))
  end

  defp aliases(tags, name) do
    parts =
      for key <- @alias_keys,
          value <- [Map.get(tags, key)],
          is_binary(value),
          part <- String.split(value, ";"),
          do: clean(part)

    parts |> Enum.reject(&(&1 == "" or &1 == name)) |> Enum.uniq()
  end

  defp clean(text) when is_binary(text) do
    text
    |> then(&Regex.replace(@control_or_semicolon, &1, " "))
    |> String.trim()
    |> String.slice(0, @name_length_max)
  end

  defp clean(_other), do: ""

  # A position is the point, or the centroid of the outer rings.
  defp position(%{"type" => "Point", "coordinates" => [lon, lat]})
       when is_number(lon) and is_number(lat), do: {:ok, %{lat: lat, lon: lon, area: 0.0}}

  defp position(%{"type" => "Polygon", "coordinates" => rings}) when is_list(rings),
    do: area_position([rings])

  defp position(%{"type" => "MultiPolygon", "coordinates" => polygons}) when is_list(polygons),
    do: area_position(polygons)

  defp position(_geometry), do: :unusable

  defp area_position([[[[_lon, lat0] | _ring] | _rings] | _polygons] = polygons) do
    outers = for [outer | _holes] <- polygons, do: ring_centroid(outer, lat0)
    total = outers |> Enum.map(& &1.area) |> Enum.sum()

    if total == 0 do
      [[[lon, lat] | _ring] | _rings] = hd(polygons)
      {:ok, %{lat: lat, lon: lon, area: 0.0}}
    else
      lon = Enum.sum(for outer <- outers, do: outer.lon * outer.area) / total
      lat = Enum.sum(for outer <- outers, do: outer.lat * outer.area) / total
      {:ok, %{lat: lat, lon: lon, area: total}}
    end
  end

  defp area_position(_polygons), do: :unusable

  # The shoelace area and centroid of one ring on the plane tangent at `lat0`,
  # measured from the ring's first vertex: absolute meters are about 1e7, and
  # their products lose a meter of the centroid to rounding.
  defp ring_centroid(ring, lat0) do
    meters_per_degree = Geodesy.meters_per_degree()
    kx = meters_per_degree * :math.cos(Geodesy.radians(lat0))

    [lon_origin, lat_origin] = hd(ring)

    points =
      for [lon, lat] <- ring,
          do: {(lon - lon_origin) * kx, (lat - lat_origin) * meters_per_degree}

    edges = Enum.zip(points, Enum.drop(points, 1))

    {twice_area, cx, cy} =
      Enum.reduce(edges, {0.0, 0.0, 0.0}, fn {{x0, y0}, {x1, y1}}, {area, cx, cy} ->
        cross = x0 * y1 - x1 * y0
        {area + cross, cx + (x0 + x1) * cross, cy + (y0 + y1) * cross}
      end)

    area = twice_area / 2

    if area == 0 do
      [lon, lat] = hd(ring)
      %{area: 0.0, lon: lon, lat: lat}
    else
      %{
        area: abs(area),
        lon: lon_origin + cx / (6 * area) / kx,
        lat: lat_origin + cy / (6 * area) / meters_per_degree
      }
    end
  end

  defp tally({:place, place}, places, counts) do
    counts =
      counts
      |> bump(:read)
      |> bump(:named)
      |> bump(:kept)
      |> bump_category(place.category, :kept)

    {[place | places], counts}
  end

  defp tally({:skipped, {:outside, category}}, places, counts) do
    {places,
     counts |> bump(:read) |> bump(:named) |> bump(:outside) |> bump_category(category, :outside)}
  end

  defp tally({:skipped, :unnamed}, places, counts), do: {places, bump(counts, :read)}

  defp tally({:skipped, :unusable}, places, counts),
    do: {places, bump(counts, :read) |> bump(:unusable)}

  defp tally({:skipped, :stop}, places, counts),
    do: {places, counts |> bump(:read) |> bump(:named) |> bump(:stops)}

  defp tally({:skipped, :excluded}, places, counts),
    do: {places, counts |> bump(:read) |> bump(:named) |> bump(:excluded)}

  defp bump(counts, key), do: Map.update!(counts, key, &(&1 + 1))

  defp bump_category(counts, category, key) do
    empty = %{kept: 0, outside: 0}
    update = fn entry -> Map.update!(entry, key, &(&1 + 1)) end
    Map.update!(counts, :by_category, &Map.update(&1, category, update.(empty), update))
  end
end
