defmodule Gobusgo.Polyline do
  @coordinate_precision 100_000
  @character_offset 63
  @character_max 126
  @chunk_bits 5
  @chunk_mask 0x1F
  @chunk_continues 0x20

  @moduledoc """
  Encodes and decodes the encoded polyline format: each point is the
  difference from the one before, latitude then longitude, at five decimal
  places, written in
  chunks of #{@chunk_bits} bits, lowest first, each chunk but a
  number's last marked as continued and every chunk offset by
  #{@character_offset} into printable ASCII. Everything here is pure.

  https://developers.google.com/maps/documentation/utilities/polylinealgorithm — checked 2026-10-14
  """

  alias Gobusgo.Assert

  @typedoc "A point as GeoJSON takes it: longitude, then latitude, in degrees."
  @type point :: [float()]

  @typedoc """
    * `:truncated`: the string ends inside a number, or after a latitude
      with no longitude.
    * `:invalid_character`: a character lies outside the format's range.
  """
  @type error :: :truncated | :invalid_character

  @doc "Returns the points `points` encodes, in order, longitude first."
  @spec decode(String.t()) :: {:ok, [point()]} | {:error, error()}
  def decode(points) when is_binary(points), do: decode_points(points, {0, 0}, [])

  @doc """
  Returns the encoded text of `points`, in order, longitude first, each
  coordinate rounded to five decimal places. `decode/1` of the result
  returns the rounded points.
  """
  @spec encode([point()]) :: String.t()
  def encode(points) when is_list(points) do
    {encoded, _position} = Enum.reduce(points, {[], {0, 0}}, &encode_point/2)
    IO.iodata_to_binary(encoded)
  end

  defp encode_point([longitude, latitude], {encoded, {latitude_before, longitude_before}}) do
    Assert.condition(is_number(latitude), "latitude must be a number")
    Assert.condition(is_number(longitude), "longitude must be a number")
    latitude_fixed = round(latitude * @coordinate_precision)
    longitude_fixed = round(longitude * @coordinate_precision)
    latitude_step = encode_number(latitude_fixed - latitude_before)
    longitude_step = encode_number(longitude_fixed - longitude_before)
    {[encoded, latitude_step, longitude_step], {latitude_fixed, longitude_fixed}}
  end

  # The sign moves into the lowest bit, and the value is written in chunks,
  # lowest first.
  defp encode_number(value) do
    shifted = Bitwise.bsl(value, 1)

    unsigned =
      case value < 0 do
        true -> Bitwise.bnot(shifted)
        false -> shifted
      end

    encode_chunks(unsigned, [])
  end

  defp encode_chunks(value, chunks) when value >= @chunk_continues do
    chunk = Bitwise.bor(Bitwise.band(value, @chunk_mask), @chunk_continues) + @character_offset
    encode_chunks(Bitwise.bsr(value, @chunk_bits), [chunks, chunk])
  end

  defp encode_chunks(value, chunks), do: [chunks, value + @character_offset]

  # Each step consumes at least two characters, so the recursion ends within
  # half the string's length.
  defp decode_points("", _position, decoded), do: {:ok, Enum.reverse(decoded)}

  defp decode_points(points, {latitude, longitude}, decoded) do
    with {:ok, latitude_step, rest} <- decode_number(points, 0, 0),
         {:ok, longitude_step, rest} <- decode_number(rest, 0, 0) do
      latitude = latitude + latitude_step
      longitude = longitude + longitude_step
      point = [longitude / @coordinate_precision, latitude / @coordinate_precision]
      Assert.condition(byte_size(rest) < byte_size(points), "a point consumes characters")
      decode_points(rest, {latitude, longitude}, [point | decoded])
    else
      {:error, :empty} -> {:error, :truncated}
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_number("", 0, 0), do: {:error, :empty}
  defp decode_number("", _result, _shift), do: {:error, :truncated}

  defp decode_number(<<character, rest::binary>>, result, shift) do
    if character >= @character_offset and character <= @character_max do
      chunk = character - @character_offset
      result = Bitwise.bor(result, Bitwise.bsl(Bitwise.band(chunk, @chunk_mask), shift))

      if chunk >= @chunk_continues do
        decode_number(rest, result, shift + @chunk_bits)
      else
        {:ok, signed(result), rest}
      end
    else
      {:error, :invalid_character}
    end
  end

  # The lowest bit carries the sign.
  defp signed(value) do
    case Bitwise.band(value, 1) do
      1 -> Bitwise.bnot(Bitwise.bsr(value, 1))
      0 -> Bitwise.bsr(value, 1)
    end
  end
end
