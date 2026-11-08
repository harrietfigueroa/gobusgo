defmodule Gobusgo.Gbfs.VehicleTileFormat do
  @magic "GBSV"
  @version 1
  @header_bytes 28
  # Two bytes each of latitude, longitude, and range, and one of form.
  @vehicle_bytes 7
  @fraction_max 0xFFFF
  @range_unknown 0xFFFF
  @range_decameters_max 0xFFFE
  @meters_per_decameter 10
  @microdegrees_per_degree 1_000_000
  @lat_microdegrees_max 90_000_000
  @lon_microdegrees_max 180_000_000

  @form_codes %{other: 0, standing_scooter: 1, seated_scooter: 2, e_bike: 3, bike: 4}

  @moduledoc """
  The packed binary block of shared vehicles that a tile and the whole-city
  file both hold, format version #{@version}. Everything here is pure, and
  every number is little-endian, the byte order of every browser a
  JavaScript reader runs in.

  A block starts with a header of #{@header_bytes} bytes: the magic
  `#{@magic}`, the format version as a `u16`, a `u16` of zero, the vehicle
  count as a `u32`, then the block's bounds as four `i32` in millionths of a
  degree: south, west, north, and east. Four columns follow, each with one
  entry per vehicle in the same order:

    * the latitude as a `u16` fraction of the way from south to north,
      #{@fraction_max} at north;
    * the longitude as a `u16` fraction of the way from west to east;
    * the remaining range as a `u16` count of decameters, at most
      #{@range_decameters_max}, or #{@range_unknown} for a vehicle whose
      range is not published;
    * the form factor as a `u8`:
      #{Enum.map_join(Enum.sort_by(@form_codes, &elem(&1, 1)), ", ", fn {form, code} -> "#{code} #{form}" end)}.

  A position is stored to a fraction of its block, so its precision is the
  block's size over #{@fraction_max}: under 0.1 m in a tile of zoom 14, and
  under 1 m across a city. A block whose bounds have no width or no height
  stores every position on that axis as 0. A block holds no vehicle
  identifier.

  `decode/1` refuses a block of another magic or version, one whose length
  does not fit its count, bounds outside the range of their axis or with
  south over north or west over east, and a form code it does not know.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Gbfs.VehicleForms

  @type bounds :: %{
          south_microdegrees: integer(),
          west_microdegrees: integer(),
          north_microdegrees: integer(),
          east_microdegrees: integer()
        }

  @type vehicle :: %{
          lat: float(),
          lon: float(),
          current_range_meters: number() | nil,
          form_factor: VehicleForms.form_factor()
        }

  @type block :: %{bounds: bounds(), vehicles: [vehicle()]}

  @type decode_error :: :magic | :version | :length | :bounds | :form_factor

  @doc "The format version of every block this module encodes."
  @spec version() :: pos_integer()
  def version, do: @version

  @doc "The form code of each form factor."
  @spec form_codes() :: %{VehicleForms.form_factor() => non_neg_integer()}
  def form_codes, do: @form_codes

  @doc """
  Returns the block of `block.vehicles` stored to `block.bounds`. A position
  outside the bounds is stored at the nearest edge. Raises
  `Gobusgo.Assert.AssertionError` for bounds that break the rules
  `decode/1` checks.
  """
  @spec encode(block()) :: binary()
  def encode(%{bounds: bounds, vehicles: vehicles}) when is_list(vehicles) do
    assert_bounds(bounds)
    count = length(vehicles)
    %{south_microdegrees: south, west_microdegrees: west} = bounds
    %{north_microdegrees: north, east_microdegrees: east} = bounds

    header =
      <<@magic::binary, @version::little-unsigned-16, 0::little-unsigned-16,
        count::little-unsigned-32, south::little-signed-32, west::little-signed-32,
        north::little-signed-32, east::little-signed-32>>

    lats = for vehicle <- vehicles, into: <<>>, do: fraction(vehicle.lat, south, north)
    lons = for vehicle <- vehicles, into: <<>>, do: fraction(vehicle.lon, west, east)
    ranges = for vehicle <- vehicles, into: <<>>, do: range(vehicle.current_range_meters)
    forms = for vehicle <- vehicles, into: <<>>, do: form(vehicle.form_factor)
    block = header <> lats <> lons <> ranges <> forms

    Assert.condition(
      byte_size(block) == block_bytes(count),
      "a block of #{count} vehicles must be #{block_bytes(count)} bytes"
    )

    block
  end

  @doc """
  Returns the bounds and the vehicles `block` holds, each position at its
  stored fraction of the bounds, or the first rule the block breaks.
  """
  @spec decode(binary()) :: {:ok, block()} | {:error, decode_error()}
  def decode(<<@magic::binary, version::little-unsigned-16, _rest::binary>>)
      when version != @version, do: {:error, :version}

  def decode(
        <<@magic::binary, @version::little-unsigned-16, _zero::little-unsigned-16,
          count::little-unsigned-32, south::little-signed-32, west::little-signed-32,
          north::little-signed-32, east::little-signed-32, columns::binary>> = block
      ) do
    bounds = %{
      south_microdegrees: south,
      west_microdegrees: west,
      north_microdegrees: north,
      east_microdegrees: east
    }

    cond do
      byte_size(block) != block_bytes(count) -> {:error, :length}
      not bounds?(bounds) -> {:error, :bounds}
      true -> decode_columns(%{bounds: bounds, count: count, columns: columns})
    end
  end

  def decode(<<@magic::binary, _rest::binary>>), do: {:error, :length}
  def decode(block) when is_binary(block), do: {:error, :magic}

  @doc "Whether `bounds` are bounds a block can be stored to."
  @spec bounds?(term()) :: boolean()
  def bounds?(%{
        south_microdegrees: south,
        west_microdegrees: west,
        north_microdegrees: north,
        east_microdegrees: east
      })
      when is_integer(south) and is_integer(west) and is_integer(north) and is_integer(east) do
    lats_valid = abs(south) <= @lat_microdegrees_max and abs(north) <= @lat_microdegrees_max
    lons_valid = abs(west) <= @lon_microdegrees_max and abs(east) <= @lon_microdegrees_max
    axes_valid = lats_valid and lons_valid
    axes_valid and south <= north and west <= east
  end

  def bounds?(_bounds), do: false

  @doc "The microdegrees of `degrees`, rounded to the nearest."
  @spec microdegrees(number()) :: integer()
  def microdegrees(degrees) when is_number(degrees), do: round(degrees * @microdegrees_per_degree)

  defp block_bytes(count), do: @header_bytes + count * @vehicle_bytes

  defp assert_bounds(bounds) do
    Assert.condition(bounds?(bounds), "bounds must be inside their axes, got: #{inspect(bounds)}")
  end

  # The fraction of the way from `low` to `high`, in microdegrees, that
  # `degrees` stands at, clamped to the edges.
  defp fraction(degrees, low, high) when is_number(degrees) do
    span = high - low

    fraction =
      case span do
        0 ->
          0

        span ->
          offset = microdegrees(degrees) - low
          offset |> Kernel.*(@fraction_max) |> Kernel./(span) |> round() |> clamp_fraction()
      end

    <<fraction::little-unsigned-16>>
  end

  defp clamp_fraction(fraction) when fraction < 0, do: 0
  defp clamp_fraction(fraction) when fraction > @fraction_max, do: @fraction_max
  defp clamp_fraction(fraction), do: fraction

  defp range(nil), do: <<@range_unknown::little-unsigned-16>>

  defp range(meters) when is_number(meters) and meters >= 0 do
    decameters = min(round(meters / @meters_per_decameter), @range_decameters_max)
    <<decameters::little-unsigned-16>>
  end

  defp form(form_factor) do
    code = Map.fetch!(@form_codes, form_factor)
    <<code::unsigned-8>>
  end

  defp decode_columns(%{bounds: bounds, count: count, columns: columns}) do
    column_bytes = count * 2

    <<lats::binary-size(^column_bytes), lons::binary-size(^column_bytes), rest::binary>> =
      columns

    <<ranges::binary-size(^column_bytes), forms::binary-size(^count)>> = rest
    forms_by_code = Map.new(@form_codes, fn {form, code} -> {code, form} end)
    codes = :binary.bin_to_list(forms)
    known_codes = Enum.all?(codes, &is_map_key(forms_by_code, &1))

    case known_codes do
      false ->
        {:error, :form_factor}

      true ->
        vehicles =
          [u16s(lats), u16s(lons), u16s(ranges), codes]
          |> Enum.zip()
          |> Enum.map(fn {lat, lon, range, code} ->
            %{
              lat: degrees(lat, bounds.south_microdegrees, bounds.north_microdegrees),
              lon: degrees(lon, bounds.west_microdegrees, bounds.east_microdegrees),
              current_range_meters: range_meters(range),
              form_factor: Map.fetch!(forms_by_code, code)
            }
          end)

        {:ok, %{bounds: bounds, vehicles: vehicles}}
    end
  end

  defp u16s(column), do: for(<<value::little-unsigned-16 <- column>>, do: value)

  defp degrees(fraction, low, high) do
    (low + fraction * (high - low) / @fraction_max) / @microdegrees_per_degree
  end

  defp range_meters(@range_unknown), do: nil
  defp range_meters(decameters), do: decameters * @meters_per_decameter
end
