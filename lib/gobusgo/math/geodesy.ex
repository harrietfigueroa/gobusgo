defmodule Gobusgo.Math.Geodesy do
  @earth_radius_meters 6_371_008.8
  @degrees_per_half_turn 180
  @meters_per_degree :math.pi() * @earth_radius_meters / @degrees_per_half_turn

  @moduledoc """
  Distances and angles on the Earth, taken as a sphere of the mean radius,
  #{@earth_radius_meters} m. Everything here is pure, and holds no place:
  a function that depends on where it measures takes the place as an
  argument.

  A position is a map of `lat` and `lon` in degrees. A distance on the
  sphere is within 0.5% of one on the ellipsoid.

  A conversion multiplies by π before it divides by 180. A precomputed
  π / 180 rounds once more, and gives other bits for about a quarter of the
  latitudes.
  """

  @type position :: %{lat: number(), lon: number()}

  @doc """
  The mean radius of the Earth in meters, IUGG's R1 of 6,371,008.7714 m for
  the GRS 80 ellipsoid rounded to the decimeter.
  """
  # https://en.wikipedia.org/wiki/Earth_radius#Arithmetic_mean_radius — checked 2026-11-09
  @spec earth_radius_meters() :: float()
  def earth_radius_meters, do: @earth_radius_meters

  @doc """
  The meters of a degree of latitude, and of a degree of longitude at the
  equator: π times the mean radius over 180, about #{round(@meters_per_degree)} m.
  """
  @spec meters_per_degree() :: float()
  def meters_per_degree, do: @meters_per_degree

  @doc "`degrees` in radians."
  @spec radians(number()) :: float()
  def radians(degrees) when is_number(degrees), do: degrees * :math.pi() / @degrees_per_half_turn

  @doc "`radians` in degrees."
  @spec degrees(number()) :: float()
  def degrees(radians) when is_number(radians), do: radians * @degrees_per_half_turn / :math.pi()

  @doc """
  The great-circle distance in meters between the positions `from` and
  `to`, by the haversine formula, which keeps its precision at the short
  distances a city holds. A pair across the antimeridian is measured the
  short way round.
  """
  @spec distance_meters(position(), position()) :: float()
  def distance_meters(%{lat: from_lat, lon: from_lon}, %{lat: to_lat, lon: to_lon})
      when is_number(from_lat) and is_number(from_lon) and is_number(to_lat) and is_number(to_lon) do
    lat_from = radians(from_lat)
    lat_to = radians(to_lat)
    half_lat = (lat_to - lat_from) / 2
    half_lon = radians(to_lon - from_lon) / 2

    a =
      :math.pow(:math.sin(half_lat), 2) +
        :math.cos(lat_from) * :math.cos(lat_to) * :math.pow(:math.sin(half_lon), 2)

    # The haversine sum can round past 1 for antipodal positions, and
    # arcsine raises past 1.
    2 * @earth_radius_meters * :math.asin(min(1.0, :math.sqrt(a)))
  end
end
