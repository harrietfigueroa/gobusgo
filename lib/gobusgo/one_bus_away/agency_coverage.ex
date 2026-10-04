defmodule Gobusgo.OneBusAway.AgencyCoverage do
  @agency_count_max 1_000
  @buffer_meters_max 100_000

  @moduledoc """
  The geometry of agency coverage: the bounds of one agency's coverage, and
  the regions that hold the coverage of a list of agencies. Everything here
  is pure.

  A coverage entry of `agencies-with-coverage` is a center (`lat`, `lon`) and
  the whole height and width of a box around it (`lat_span`, `lon_span`), in
  degrees. Bounds are the edges of that box: `south`, `west`, `north`, and
  `east`, in degrees, with `south <= north` and `west <= east`.

  ## Coverage without bounds

  `bounds/1` returns these as values:

    * `:coverage_missing`: all four numbers are zero, which is how the source
      reports an agency with no coverage
    * `{:coverage_invalid, :lat_span}`, `{:coverage_invalid, :lon_span}`: a
      negative span
    * `{:coverage_invalid, :lat}`: an edge beyond a pole
    * `{:coverage_invalid, :lon}`: an edge beyond the antimeridian; a box
      across it has no bounds with `west <= east`

  ## Regions

  `extract_regions/2` takes at most #{@agency_count_max} agencies and a
  buffer of at most #{@buffer_meters_max} meters, and returns:

    * `:agencies`: each agency's own bounds, without the buffer, in agency
      identifier order
    * `:regions`: the buffered bounds, with every two that overlap or touch
      combined into the bounds that hold both, so no two regions share an
      area. Each region names its agencies in identifier order, and the
      regions are ordered by their west edge, then south, east, and north
    * `:skipped`: each agency whose coverage has no bounds, with the reason,
      in agency identifier order
  """

  alias Gobusgo.Assert

  @latitude_degrees_max 90.0
  @longitude_degrees_max 180.0
  @meters_per_latitude_degree 111_320
  @radians_per_degree :math.pi() / 180

  @type coverage :: %{lat: number(), lon: number(), lat_span: number(), lon_span: number()}
  @type bounds :: %{south: float(), west: float(), north: float(), east: float()}
  @type coverage_error ::
          :coverage_missing | {:coverage_invalid, :lat | :lon | :lat_span | :lon_span}
  @type agency :: %{:id => String.t(), :coverage => coverage(), optional(atom()) => term()}
  @type region :: %{agency_ids: [String.t(), ...], bounds: bounds()}
  @type extract :: %{
          agencies: [%{agency_id: String.t(), bounds: bounds()}],
          regions: [region()],
          skipped: [%{agency_id: String.t(), reason: coverage_error()}]
        }

  @doc "Returns the bounds of `coverage`, or why it has none."
  @spec bounds(coverage()) :: {:ok, bounds()} | {:error, coverage_error()}
  def bounds(%{lat: lat, lon: lon, lat_span: lat_span, lon_span: lon_span})
      when is_number(lat) and is_number(lon) and is_number(lat_span) and is_number(lon_span) do
    bounds = %{
      south: lat - lat_span / 2,
      west: lon - lon_span / 2,
      north: lat + lat_span / 2,
      east: lon + lon_span / 2
    }

    cond do
      Enum.all?([lat, lon, lat_span, lon_span], &(&1 == 0)) -> {:error, :coverage_missing}
      lat_span < 0 -> {:error, {:coverage_invalid, :lat_span}}
      lon_span < 0 -> {:error, {:coverage_invalid, :lon_span}}
      bounds.south < -@latitude_degrees_max -> {:error, {:coverage_invalid, :lat}}
      bounds.north > @latitude_degrees_max -> {:error, {:coverage_invalid, :lat}}
      bounds.west < -@longitude_degrees_max -> {:error, {:coverage_invalid, :lon}}
      bounds.east > @longitude_degrees_max -> {:error, {:coverage_invalid, :lon}}
      true -> {:ok, bounds}
    end
  end

  @doc """
  Returns the bounds of every agency in `agencies`, the regions that hold
  them once each is widened by `buffer_meters` on every side, and the
  agencies whose coverage has no bounds.
  """
  @spec extract_regions([agency()], non_neg_integer()) :: extract()
  def extract_regions(agencies, buffer_meters) when is_list(agencies) do
    agency_count = length(agencies)

    Assert.condition(
      agency_count <= @agency_count_max,
      "agency count #{agency_count} exceeds #{@agency_count_max}"
    )

    Assert.condition(
      is_integer(buffer_meters),
      "buffer_meters must be an integer, got: #{inspect(buffer_meters)}"
    )

    Assert.condition(
      buffer_meters >= 0,
      "buffer_meters must be at least 0, got: #{buffer_meters}"
    )

    Assert.condition(
      buffer_meters <= @buffer_meters_max,
      "buffer_meters #{buffer_meters} exceeds #{@buffer_meters_max}"
    )

    {located, skipped} = locate(Enum.sort_by(agencies, & &1.id))

    regions =
      located
      |> Enum.map(&%{agency_ids: [&1.agency_id], bounds: buffer(&1.bounds, buffer_meters)})
      |> combine()

    region_agency_count = regions |> Enum.map(&length(&1.agency_ids)) |> Enum.sum()

    Assert.condition(
      region_agency_count == length(located),
      "regions name #{region_agency_count} agencies, expected #{length(located)}"
    )

    Assert.condition(
      length(located) + length(skipped) == agency_count,
      "#{length(located)} located and #{length(skipped)} skipped agencies, expected #{agency_count}"
    )

    %{agencies: located, regions: regions, skipped: skipped}
  end

  defp locate(agencies) do
    {located, skipped} =
      Enum.reduce(agencies, {[], []}, fn %{id: id, coverage: coverage}, {located, skipped} ->
        case bounds(coverage) do
          {:ok, bounds} -> {[%{agency_id: id, bounds: bounds} | located], skipped}
          {:error, reason} -> {located, [%{agency_id: id, reason: reason} | skipped]}
        end
      end)

    {Enum.reverse(located), Enum.reverse(skipped)}
  end

  defp buffer(bounds, buffer_meters) do
    latitude_degrees = buffer_meters / @meters_per_latitude_degree
    south = max(bounds.south - latitude_degrees, -@latitude_degrees_max)
    north = min(bounds.north + latitude_degrees, @latitude_degrees_max)

    # A degree of longitude is shortest at the edge farthest from the equator,
    # so that edge sets the degrees that cover the buffer along the whole box.
    # At a pole the cosine is a tiny positive float, never zero, and the
    # quotient is clamped below.
    latitude_abs_max = max(abs(south), abs(north))
    longitude_degrees = latitude_degrees / :math.cos(latitude_abs_max * @radians_per_degree)

    %{
      south: south,
      west: max(bounds.west - longitude_degrees, -@longitude_degrees_max),
      north: north,
      east: min(bounds.east + longitude_degrees, @longitude_degrees_max)
    }
  end

  defp combine(regions) do
    regions
    |> Enum.reduce([], &combine_region/2)
    |> Enum.map(&%{&1 | agency_ids: Enum.sort(&1.agency_ids)})
    |> Enum.sort_by(&{&1.bounds.west, &1.bounds.south, &1.bounds.east, &1.bounds.north})
  end

  # `regions` are disjoint. A pass joins `region` with every one it reaches,
  # and the grown region can reach more, so passes repeat until one joins
  # nothing. Every joining pass takes at least one region out of `regions`,
  # which bounds the passes by their count.
  defp combine_region(region, regions) do
    combined =
      Enum.reduce_while(0..length(regions), {region, regions}, fn _pass, {region, apart} ->
        case Enum.split_with(apart, &overlap?(&1.bounds, region.bounds)) do
          {[], apart} -> {:halt, [region | apart]}
          {reached, apart} -> {:cont, {Enum.reduce(reached, region, &union/2), apart}}
        end
      end)

    Assert.condition(is_list(combined), "combining #{length(regions)} regions did not finish")
    combined
  end

  defp overlap?(a, b) do
    a.south <= b.north and b.south <= a.north and a.west <= b.east and b.west <= a.east
  end

  defp union(a, b) do
    %{
      agency_ids: a.agency_ids ++ b.agency_ids,
      bounds: %{
        south: min(a.bounds.south, b.bounds.south),
        west: min(a.bounds.west, b.bounds.west),
        north: max(a.bounds.north, b.bounds.north),
        east: max(a.bounds.east, b.bounds.east)
      }
    }
  end
end
