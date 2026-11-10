defmodule Gobusgo.Packed.Columns do
  @moduledoc """
  Fixed-width columns of the packed container: a section of one value per
  record, each `u8`, `u16`, `u32`, or `i32`, little-endian. Everything here
  is pure.
  """

  alias Gobusgo.Assert

  @typedoc "The type of a column's values."
  @type type :: :u8 | :u16 | :u32 | :i32

  @doc "The bytes of one value of `type`."
  @spec width(type()) :: 1 | 2 | 4
  def width(:u8), do: 1
  def width(:u16), do: 2
  def width(:u32), do: 4
  def width(:i32), do: 4

  @doc "Returns the section that holds `values`, each within the range of `type`."
  @spec encode(type(), [integer()]) :: binary()
  def encode(type, values) when is_list(values) do
    IO.iodata_to_binary(for value <- values, do: encode_value(type, value))
  end

  defp encode_value(:u8, value), do: <<assert_range(:u8, value, 0, 255)>>

  defp encode_value(:u16, value), do: <<assert_range(:u16, value, 0, 65_535)::little-16>>

  defp encode_value(:u32, value), do: <<assert_range(:u32, value, 0, 4_294_967_295)::little-32>>

  defp encode_value(:i32, value),
    do: <<assert_range(:i32, value, -2_147_483_648, 2_147_483_647)::little-signed-32>>

  defp assert_range(type, value, minimum, maximum) do
    Assert.condition(
      is_integer(value) and value >= minimum and value <= maximum,
      "a #{type} must be an integer from #{minimum} to #{maximum}, got: #{inspect(value)}"
    )

    value
  end

  @doc """
  Returns the `count` values of `type` that `section` holds, or
  `:bad_section_size` when it is not `count` values long.
  """
  @spec decode(type(), binary(), non_neg_integer()) ::
          {:ok, [integer()]} | {:error, :bad_section_size}
  def decode(type, section, count) when is_binary(section) and is_integer(count) do
    if byte_size(section) == count * width(type) do
      {:ok, decode_values(type, section)}
    else
      {:error, :bad_section_size}
    end
  end

  defp decode_values(_type, <<>>), do: []

  defp decode_values(:u8, <<value, rest::binary>>), do: [value | decode_values(:u8, rest)]

  defp decode_values(:u16, <<value::little-16, rest::binary>>),
    do: [value | decode_values(:u16, rest)]

  defp decode_values(:u32, <<value::little-32, rest::binary>>),
    do: [value | decode_values(:u32, rest)]

  defp decode_values(:i32, <<value::little-signed-32, rest::binary>>),
    do: [value | decode_values(:i32, rest)]
end
