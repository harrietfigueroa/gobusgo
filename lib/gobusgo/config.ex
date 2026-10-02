defmodule Gobusgo.Config do
  @moduledoc """
  Validated access to runtime settings. Everything here is pure: callers pass
  the application environment in, which keeps validation testable without
  global state.
  """

  @type one_bus_away :: %{base_url: String.t(), api_key: String.t()}
  @type one_bus_away_error :: {:missing, :base_url | :api_key}

  @one_bus_away_keys [:base_url, :api_key]

  @doc """
  Returns the OneBusAway settings from `env`, or the first missing key.
  A nil or blank value counts as missing.
  """
  @spec fetch_one_bus_away(Keyword.t()) :: {:ok, one_bus_away()} | {:error, one_bus_away_error()}
  def fetch_one_bus_away(env) when is_list(env) do
    Enum.reduce_while(@one_bus_away_keys, {:ok, %{}}, fn key, {:ok, settings} ->
      case Keyword.get(env, key) do
        value when is_binary(value) ->
          if String.trim(value) == "" do
            {:halt, {:error, {:missing, key}}}
          else
            {:cont, {:ok, Map.put(settings, key, value)}}
          end

        nil ->
          {:halt, {:error, {:missing, key}}}
      end
    end)
  end

  @doc "Reads the OneBusAway settings configured for the running application."
  @spec one_bus_away() :: {:ok, one_bus_away()} | {:error, one_bus_away_error()}
  def one_bus_away do
    :gobusgo |> Application.get_env(:one_bus_away, []) |> fetch_one_bus_away()
  end
end
