defmodule Gobusgo.Intersections.Names do
  @name_length_max 200
  @key_pattern ~r/\A[A-Z0-9]+( [A-Z0-9]+)*\z/

  @moduledoc """
  The key a road's name is stored and searched by, from
  `Gobusgo.Addresses.Normalize`, so a name OpenStreetMap holds and a name a
  rider types reach one key. A name of #{@name_length_max} characters or
  more, or whose key holds anything but upper case ASCII letters, digits,
  and single spaces, is `:unsupported`: the browser slices a key by
  character to choose its shard, and a character outside that alphabet
  slices differently there than here wherever the two languages' case
  rules or character boundaries differ. Everything here is pure.
  """

  alias Gobusgo.Addresses.Normalize

  @doc """
  The street key of `name` and the key of the shard it is chosen by, the
  street's name with its spaces removed, or `:unsupported`.
  """
  @spec key(String.t()) :: {:ok, %{key: String.t(), name_key: String.t()}} | :unsupported
  def key(name) when is_binary(name) do
    if String.length(name) < @name_length_max do
      name |> Normalize.tokenize() |> Normalize.parse_street() |> checked()
    else
      :unsupported
    end
  end

  @doc "The shard key of `key`, a street key `key/1` returned."
  @spec name_key(String.t()) :: String.t()
  def name_key(key) when is_binary(key) do
    key |> Normalize.tokenize() |> Normalize.parse_street() |> Normalize.name_key()
  end

  defp checked(%{name: ""}), do: :unsupported

  defp checked(street) do
    key = Normalize.street_key(street)

    if Regex.match?(@key_pattern, key) do
      {:ok, %{key: key, name_key: Normalize.name_key(street)}}
    else
      :unsupported
    end
  end
end
