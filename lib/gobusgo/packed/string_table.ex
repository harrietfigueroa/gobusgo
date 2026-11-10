defmodule Gobusgo.Packed.StringTable do
  @moduledoc """
  The string table of the packed container, its section 0: a `u32` count of
  entries, then each entry as a varint byte length and that many bytes of
  UTF-8. Records refer to an entry by its index. The builder interns a
  string once and numbers entries in the order of first use, so the same
  input order gives the same table. Everything here is pure.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Packed.Varint

  @typedoc "Strings interned so far, with the index of each."
  @opaque builder :: %{indexes: %{String.t() => non_neg_integer()}, strings: [String.t()]}

  @doc "Returns a builder with no strings."
  @spec new() :: builder()
  def new, do: %{indexes: %{}, strings: []}

  @doc "Returns the index of `string` in `builder`, adding it when it is new."
  @spec intern(builder(), String.t()) :: {non_neg_integer(), builder()}
  def intern(%{indexes: indexes, strings: strings} = builder, string) when is_binary(string) do
    Assert.condition(String.valid?(string), "a table entry must be UTF-8")

    case Map.fetch(indexes, string) do
      {:ok, index} ->
        {index, builder}

      :error ->
        index = map_size(indexes)
        {index, %{indexes: Map.put(indexes, string, index), strings: [string | strings]}}
    end
  end

  @doc "Returns the strings of `builder` in index order."
  @spec strings(builder()) :: [String.t()]
  def strings(%{strings: strings}), do: Enum.reverse(strings)

  @doc "Returns the section that holds `strings`, which are unique."
  @spec encode([String.t()]) :: binary()
  def encode(strings) when is_list(strings) do
    Assert.condition(
      length(Enum.uniq(strings)) == length(strings),
      "table entries must be unique"
    )

    entries =
      for string <- strings do
        Assert.condition(String.valid?(string), "a table entry must be UTF-8")
        [Varint.encode(byte_size(string)), string]
      end

    IO.iodata_to_binary([<<length(strings)::little-32>>, entries])
  end

  @doc """
  Returns the entries of the section `section`, in index order, or the first
  rule it breaks: `:truncated`, `:bad_varint`, `:bad_utf8`, or
  `:bad_string_table` for bytes left after the last entry.
  """
  @spec decode(binary()) ::
          {:ok, [String.t()]} | {:error, :truncated | :bad_varint | :bad_utf8 | :bad_string_table}
  def decode(<<count::little-32, entries::binary>>) do
    if count <= byte_size(entries) do
      decode_entries(entries, count, [])
    else
      {:error, :truncated}
    end
  end

  def decode(section) when is_binary(section), do: {:error, :truncated}

  defp decode_entries(<<>>, 0, strings), do: {:ok, Enum.reverse(strings)}
  defp decode_entries(_rest, 0, _strings), do: {:error, :bad_string_table}

  defp decode_entries(binary, remaining, strings) do
    with {:ok, length, rest} <- Varint.decode(binary),
         {:ok, string, after_string} <- take(rest, length) do
      decode_entries(after_string, remaining - 1, [string | strings])
    end
  end

  defp take(binary, length) when length <= byte_size(binary) do
    <<string::binary-size(^length), rest::binary>> = binary

    if String.valid?(string) do
      {:ok, string, rest}
    else
      {:error, :bad_utf8}
    end
  end

  defp take(_binary, _length), do: {:error, :truncated}
end
