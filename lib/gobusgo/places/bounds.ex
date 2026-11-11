defmodule Gobusgo.Places.Bounds do
  @moduledoc """
  The geographic box the places file covers, `%{south:, west:, north:, east:}`
  in degrees. Everything here is pure.
  """

  alias Gobusgo.Basemap.Manifest

  @latitude_max 90
  @longitude_max 180

  @type t :: %{south: number(), west: number(), north: number(), east: number()}

  @doc """
  Reads `south,west,north,east` as the `--bounds` option writes it, or returns
  `{:error, :invalid_bounds}` for anything that is not four numbers in range
  with south below north and west below east.
  """
  @spec parse(String.t()) :: {:ok, t()} | {:error, :invalid_bounds}
  def parse(text) when is_binary(text) do
    parts = String.split(text, ",")
    numbers = for part <- parts, {number, ""} <- [Float.parse(String.trim(part))], do: number

    with true <- length(parts) == 4 and length(numbers) == 4,
         [south, west, north, east] = numbers,
         bounds = %{south: south, west: west, north: north, east: east},
         true <- valid?(bounds) do
      {:ok, bounds}
    else
      _invalid -> {:error, :invalid_bounds}
    end
  end

  @doc "The box that holds every archive of the manifest."
  @spec from_manifest(Manifest.t()) :: t()
  def from_manifest(%{archives: [first | rest]}) do
    Enum.reduce(rest, first.bounds, fn %{bounds: next}, union -> union(union, next) end)
  end

  @doc "Whether the position lies inside the box, its edges included."
  @spec contains?(t(), %{lat: number(), lon: number()}) :: boolean()
  def contains?(%{south: south, west: west, north: north, east: east}, %{lat: lat, lon: lon}) do
    within_latitude = lat >= south and lat <= north
    within_longitude = lon >= west and lon <= east
    within_latitude and within_longitude
  end

  defp union(left, right) do
    %{
      south: min(left.south, right.south),
      west: min(left.west, right.west),
      north: max(left.north, right.north),
      east: max(left.east, right.east)
    }
  end

  defp valid?(%{south: south, west: west, north: north, east: east}) do
    latitudes = abs(south) <= @latitude_max and abs(north) <= @latitude_max
    longitudes = abs(west) <= @longitude_max and abs(east) <= @longitude_max
    ordered = south < north and west < east
    latitudes and longitudes and ordered
  end
end
