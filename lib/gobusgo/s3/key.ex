defmodule Gobusgo.S3.Key do
  @moduledoc """
  The key a logical destination is stored under in the bucket: the key
  prefix followed by the destination. Everything here is pure.

  The key prefix is empty, or one or more destination segments each followed
  by `/`, so every key under it is the prefix and a destination and nothing
  else in the bucket's keys reads as one of the application's.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Destination

  @doc "Whether `prefix` is a key prefix: empty, or destination segments that end in `/`."
  @spec prefix?(String.t()) :: boolean()
  def prefix?(""), do: true

  def prefix?(prefix) when is_binary(prefix) do
    match?({:ok, %{remainder: ""}}, Destination.validate_prefix(prefix))
  end

  @doc """
  Returns the key prefix of `options`: its `:prefix`, or the one under
  `config :gobusgo, Gobusgo.S3`.
  """
  @spec prefix(Keyword.t()) :: String.t()
  def prefix(options) when is_list(options) do
    prefix =
      Keyword.get_lazy(options, :prefix, fn ->
        :gobusgo |> Application.get_env(Gobusgo.S3, []) |> Keyword.get(:prefix)
      end)

    Assert.condition(is_binary(prefix), "prefix must be configured, got: #{inspect(prefix)}")
    Assert.condition(prefix?(prefix), "prefix must be empty or segments ending in /: #{prefix}")
    prefix
  end

  @doc "Returns the key of `destination`, or of a prefix of destinations, under `prefix`."
  @spec from_destination(String.t(), String.t()) :: String.t()
  def from_destination(prefix, destination) when is_binary(prefix) and is_binary(destination) do
    prefix <> destination
  end

  @doc """
  Returns the destination `key` stores under `prefix`, or `:error` for a key
  outside the prefix and for one whose remainder is no valid destination.
  """
  @spec to_destination(String.t(), String.t()) :: {:ok, String.t()} | :error
  def to_destination(prefix, key) when is_binary(prefix) and is_binary(key) do
    with true <- String.starts_with?(key, prefix),
         destination = binary_part(key, byte_size(prefix), byte_size(key) - byte_size(prefix)),
         {:ok, _segments} <- Destination.validate(destination) do
      {:ok, destination}
    else
      _other -> :error
    end
  end
end
