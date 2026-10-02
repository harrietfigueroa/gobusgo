defmodule Gobusgo.CanonicalJson do
  @moduledoc """
  Compact JSON with object keys sorted, so the bytes, and any hash over them,
  are a function of the value alone. Everything here is pure.
  """

  @doc "Encodes `value` as compact JSON with the keys of every object sorted."
  @spec encode(term()) :: binary()
  def encode(value) do
    value |> JSON.encode_to_iodata!(&encode_sorted/2) |> IO.iodata_to_binary()
  end

  # A map's iteration order depends on its size, so the keys are sorted
  # before encoding.
  defp encode_sorted(value, encoder) when is_map(value) and not is_struct(value) do
    value |> Enum.sort_by(fn {key, _value} -> key end) |> :json.encode_key_value_list(encoder)
  end

  defp encode_sorted(value, encoder), do: JSON.protocol_encode(value, encoder)
end
