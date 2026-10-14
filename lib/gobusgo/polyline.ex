defmodule Gobusgo.Polyline do
  @coordinate_precision 100_000
  @character_offset 63
  @character_max 126
  @chunk_bits 5
  @chunk_mask 0x1F
  @chunk_continues 0x20

  @moduledoc """
  Decodes the encoded polyline format: each point is the difference from the
  one before, latitude then longitude, at five decimal places, written in
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
