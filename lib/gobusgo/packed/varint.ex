defmodule Gobusgo.Packed.Varint do
  @value_max 4_294_967_295
  @bytes_max 5
  @zigzag_magnitude_max 2_147_483_647

  @moduledoc """
  The unsigned LEB128 varint and the zigzag mapping of the packed container.
  A varint holds a value up to #{@value_max} in at most #{@bytes_max} bytes,
  seven bits to a byte, the low bits first, with the high bit of a byte set
  while more follow. Zigzag maps a signed integer of magnitude up to
  #{@zigzag_magnitude_max} to an unsigned one, so small deltas of either
  sign stay short. Everything here is pure.
  """

  import Bitwise

  alias Gobusgo.Assert

  @doc "The largest value a varint holds."
  @spec value_max() :: pos_integer()
  def value_max, do: @value_max

  @doc "Returns the varint of `value`, an integer from 0 to `value_max/0`."
  @spec encode(non_neg_integer()) :: binary()
  def encode(value) when is_integer(value) do
    Assert.condition(value >= 0, "varint value must not be negative, got: #{value}")
    Assert.condition(value <= @value_max, "varint value must fit 32 bits, got: #{value}")
    encode_bytes(value)
  end

  defp encode_bytes(value) when value < 128, do: <<value>>

  defp encode_bytes(value) do
    <<(value &&& 127) ||| 128, encode_bytes(value >>> 7)::binary>>
  end

  @doc """
  Returns the value of the varint at the start of `binary` and the bytes
  after it. A varint longer than #{@bytes_max} bytes or past `value_max/0` is
  `:bad_varint`, and one that `binary` ends inside is `:truncated`.
  """
  @spec decode(binary()) ::
          {:ok, non_neg_integer(), binary()} | {:error, :bad_varint | :truncated}
  def decode(binary) when is_binary(binary), do: decode(binary, 0, 0)

  defp decode(<<>>, _index, _value), do: {:error, :truncated}

  defp decode(<<byte, rest::binary>>, index, value) do
    value = value + (byte &&& 127) * Integer.pow(128, index)
    is_last = byte < 128
    is_past_length = index + 1 >= @bytes_max

    cond do
      value > @value_max -> {:error, :bad_varint}
      is_last -> {:ok, value, rest}
      is_past_length -> {:error, :bad_varint}
      true -> decode(rest, index + 1, value)
    end
  end

  @doc "Returns the zigzag of `integer`, whose magnitude is at most #{@zigzag_magnitude_max}."
  @spec zigzag(integer()) :: non_neg_integer()
  def zigzag(integer) when is_integer(integer) do
    Assert.condition(
      abs(integer) <= @zigzag_magnitude_max,
      "zigzag magnitude must fit 31 bits, got: #{integer}"
    )

    if integer >= 0 do
      2 * integer
    else
      -2 * integer - 1
    end
  end

  @doc "Returns the integer whose zigzag is `value`."
  @spec unzigzag(non_neg_integer()) :: integer()
  def unzigzag(value) when is_integer(value) and value >= 0 do
    if rem(value, 2) == 0 do
      div(value, 2)
    else
      -div(value + 1, 2)
    end
  end
end
