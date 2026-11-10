defmodule Gobusgo.Packed.Positions do
  @microdegrees_per_degree 1_000_000
  @latitude_max 90 * @microdegrees_per_degree
  @longitude_max 180 * @microdegrees_per_degree
  @unknown -2_147_483_648
  @position_bytes 8

  @moduledoc """
  Positions in the packed container, as `{latitude, longitude}` in whole
  microdegrees, `round(degrees * #{@microdegrees_per_degree})`. A position is
  stored as two `i32`, latitude then longitude, and an unknown position as
  #{@unknown} on both axes. A latitude past ±90 degrees, a longitude past
  ±180, and an unknown on one axis alone are refused. A path is a varint
  count of points, then per point the zigzag varint delta of latitude and
  of longitude from the point before it, the first from `{0, 0}`. Everything
  here is pure.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Packed.Varint

  @typedoc "A known position in microdegrees."
  @type point :: {integer(), integer()}

  @typedoc "A position in microdegrees, or `:unknown`."
  @type position :: point() | :unknown

  @doc "The microdegrees of a degree."
  @spec microdegrees_per_degree() :: pos_integer()
  def microdegrees_per_degree, do: @microdegrees_per_degree

  @doc "The value of both axes of an unknown position."
  @spec unknown() :: integer()
  def unknown, do: @unknown

  @doc "Whether `point` is a latitude and a longitude within range."
  @spec point?(term()) :: boolean()
  def point?({lat, lon}) when is_integer(lat) and is_integer(lon) do
    is_latitude = abs(lat) <= @latitude_max
    is_longitude = abs(lon) <= @longitude_max
    is_latitude and is_longitude
  end

  def point?(_other), do: false

  @doc "Returns the section of `positions`, eight bytes each."
  @spec encode([position()]) :: binary()
  def encode(positions) when is_list(positions) do
    IO.iodata_to_binary(for position <- positions, do: encode_position(position))
  end

  defp encode_position(:unknown), do: <<@unknown::little-signed-32, @unknown::little-signed-32>>

  defp encode_position({lat, lon} = point) do
    Assert.condition(point?(point), "a position must be within range, got: #{inspect(point)}")
    <<lat::little-signed-32, lon::little-signed-32>>
  end

  @doc """
  Returns the `count` positions `section` holds: `:bad_section_size` when it
  is not `count` positions long, and `:bad_position` for one out of range or
  unknown on one axis alone.
  """
  @spec decode(binary(), non_neg_integer()) ::
          {:ok, [position()]} | {:error, :bad_section_size | :bad_position}
  def decode(section, count) when is_binary(section) and is_integer(count) do
    if byte_size(section) == count * @position_bytes do
      decode_positions(section, [])
    else
      {:error, :bad_section_size}
    end
  end

  defp decode_positions(<<>>, positions), do: {:ok, Enum.reverse(positions)}

  defp decode_positions(
         <<@unknown::little-signed-32, @unknown::little-signed-32, rest::binary>>,
         positions
       ) do
    decode_positions(rest, [:unknown | positions])
  end

  defp decode_positions(<<lat::little-signed-32, lon::little-signed-32, rest::binary>>, positions) do
    if point?({lat, lon}) do
      decode_positions(rest, [{lat, lon} | positions])
    else
      {:error, :bad_position}
    end
  end

  @doc "Returns the path through `points`, each a known position."
  @spec encode_path([point()]) :: binary()
  def encode_path(points) when is_list(points) do
    {deltas, _last} = Enum.map_reduce(points, {0, 0}, &encode_delta/2)
    IO.iodata_to_binary([Varint.encode(length(points)), deltas])
  end

  defp encode_delta({lat, lon} = point, {last_lat, last_lon}) do
    Assert.condition(point?(point), "a path point must be within range, got: #{inspect(point)}")
    lat_delta = Varint.encode(Varint.zigzag(lat - last_lat))
    lon_delta = Varint.encode(Varint.zigzag(lon - last_lon))
    {[lat_delta, lon_delta], point}
  end

  @doc """
  Returns the path at the start of `binary` and the bytes after it. A path
  whose count the bytes cannot hold, at least two per point, is `:truncated`.
  """
  @spec decode_path(binary()) ::
          {:ok, [point()], binary()} | {:error, :bad_varint | :truncated | :bad_position}
  def decode_path(binary) when is_binary(binary) do
    with {:ok, count, rest} <- Varint.decode(binary) do
      if count * 2 <= byte_size(rest) do
        decode_points(rest, count, {0, 0}, [])
      else
        {:error, :truncated}
      end
    end
  end

  defp decode_points(rest, 0, _last, points), do: {:ok, Enum.reverse(points), rest}

  defp decode_points(binary, remaining, {last_lat, last_lon}, points) do
    with {:ok, lat_zigzag, after_lat} <- Varint.decode(binary),
         {:ok, lon_zigzag, after_lon} <- Varint.decode(after_lat) do
      point = {last_lat + Varint.unzigzag(lat_zigzag), last_lon + Varint.unzigzag(lon_zigzag)}

      if point?(point) do
        decode_points(after_lon, remaining - 1, point, [point | points])
      else
        {:error, :bad_position}
      end
    end
  end
end
