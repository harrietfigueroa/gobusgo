defmodule Gobusgo.Addresses.Rows do
  @row_bytes 13
  @microdegrees_per_degree 1_000_000
  @latitude_degrees_max 90
  @longitude_degrees_max 180

  @moduledoc """
  The packed rows of one street's addresses, kept as one binary instead of a
  term per address so the 654,000 addresses of a county sit off the heap of
  the build.

  A row is #{@row_bytes} bytes, big-endian: the house number as `u32`, the
  number's letter suffix as one byte (`0` for none, else an upper case ASCII
  letter), and the position as two `i32` microdegrees, latitude then
  longitude. Everything here is pure.

  `merge/1` sorts a street's rows by number and then suffix and joins the
  rows of one address into a single row at the mean of their positions, so a
  point repeated for a building's units is one address.
  """

  alias Gobusgo.Assert

  @type address :: %{
          number: non_neg_integer(),
          suffix: String.t(),
          lat_microdegrees: integer(),
          lon_microdegrees: integer()
        }

  @doc "The bytes of one row."
  @spec row_bytes() :: pos_integer()
  def row_bytes, do: @row_bytes

  @doc "The microdegrees of a degree."
  @spec microdegrees_per_degree() :: pos_integer()
  def microdegrees_per_degree, do: @microdegrees_per_degree

  @doc """
  The position in microdegrees of `degrees`, rounded to the nearest whole
  microdegree, or `:invalid` for a latitude or a longitude outside the range
  the globe has.
  """
  @spec microdegrees(%{lat: float(), lon: float()}) ::
          {:ok, %{lat: integer(), lon: integer()}} | :invalid
  def microdegrees(%{lat: lat, lon: lon}) when is_number(lat) and is_number(lon) do
    is_latitude = abs(lat) <= @latitude_degrees_max
    is_longitude = abs(lon) <= @longitude_degrees_max

    if is_latitude and is_longitude do
      {:ok,
       %{
         lat: round(lat * @microdegrees_per_degree),
         lon: round(lon * @microdegrees_per_degree)
       }}
    else
      :invalid
    end
  end

  @doc "The row of `address`."
  @spec pack(address()) :: binary()
  def pack(%{number: number, suffix: suffix, lat_microdegrees: lat, lon_microdegrees: lon})
      when is_integer(number) and number >= 0 and number <= 0xFFFFFFFF do
    suffix_byte = suffix_byte(suffix)
    <<number::unsigned-32, suffix_byte::unsigned-8, lat::signed-32, lon::signed-32>>
  end

  defp suffix_byte(""), do: 0
  defp suffix_byte(<<letter>>) when letter in ?A..?Z, do: letter

  @doc "The addresses of `rows`, in the order the rows hold them."
  @spec unpack(binary()) :: [address()]
  def unpack(rows) when is_binary(rows) do
    Assert.condition(
      rem(byte_size(rows), @row_bytes) == 0,
      "rows are #{@row_bytes} bytes each, got #{byte_size(rows)} bytes"
    )

    for <<number::unsigned-32, suffix_byte::unsigned-8, lat::signed-32,
          lon::signed-32 <-
            rows>> do
      %{
        number: number,
        suffix: suffix_text(suffix_byte),
        lat_microdegrees: lat,
        lon_microdegrees: lon
      }
    end
  end

  defp suffix_text(0), do: ""
  defp suffix_text(letter), do: <<letter>>

  @doc "The count of rows in `rows`."
  @spec count(binary()) :: non_neg_integer()
  def count(rows) when is_binary(rows), do: div(byte_size(rows), @row_bytes)

  @doc """
  The rows of `rows` sorted by number and suffix, one row per address at the
  mean position of the rows it joins, rounded to the nearest microdegree.
  """
  @spec merge(binary()) :: binary()
  def merge(rows) when is_binary(rows) do
    rows
    |> unpack()
    |> Enum.group_by(&{&1.number, &1.suffix})
    |> Enum.sort_by(fn {key, _group} -> key end)
    |> Enum.map(fn {{number, suffix}, group} ->
      group_count = length(group)

      pack(%{
        number: number,
        suffix: suffix,
        lat_microdegrees: mean(group, :lat_microdegrees, group_count),
        lon_microdegrees: mean(group, :lon_microdegrees, group_count)
      })
    end)
    |> IO.iodata_to_binary()
  end

  defp mean(group, field, group_count) do
    sum = Enum.reduce(group, 0, fn address, total -> total + Map.fetch!(address, field) end)
    round(sum / group_count)
  end
end
