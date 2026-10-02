defmodule Gobusgo.Config do
  @moduledoc """
  Validated access to runtime settings. Everything here is pure: callers pass
  the application environment in, which keeps validation testable without
  global state.
  """

  @type one_bus_away :: %{base_url: String.t(), api_key: String.t()}
  @type one_bus_away_error :: {:missing, :base_url | :api_key}

  @type http :: %{ip: :inet.ip_address(), port: :inet.port_number()}
  @type http_error :: {:invalid, :host | :port}

  @one_bus_away_keys [:base_url, :api_key]
  @http_host_default "127.0.0.1"
  @http_port_default 4000
  @http_port_min 1
  @http_port_max 65_535

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

  @doc """
  Returns the HTTP listener settings from `env`: `:host`, an IPv4 or IPv6
  address as text, and `:port`, a decimal port number as text. A nil or
  blank value takes the default, `#{@http_host_default}` and
  `#{@http_port_default}`. Returns the first value that is not valid.
  """
  @spec fetch_http(Keyword.t()) :: {:ok, http()} | {:error, http_error()}
  def fetch_http(env) when is_list(env) do
    with {:ok, ip} <- parse_ip(text(env, :host) || @http_host_default),
         {:ok, port} <- parse_port(text(env, :port)) do
      {:ok, %{ip: ip, port: port}}
    end
  end

  @doc "Reads the HTTP listener settings configured for the running application."
  @spec http() :: {:ok, http()} | {:error, http_error()}
  def http do
    :gobusgo |> Application.get_env(:http, []) |> fetch_http()
  end

  defp text(env, key) do
    case Keyword.get(env, key) do
      value when is_binary(value) -> if String.trim(value) == "", do: nil, else: value
      nil -> nil
    end
  end

  defp parse_ip(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, ip}
      {:error, :einval} -> {:error, {:invalid, :host}}
    end
  end

  defp parse_port(nil), do: {:ok, @http_port_default}

  defp parse_port(text) do
    case Integer.parse(text) do
      {port, ""} when port >= @http_port_min and port <= @http_port_max -> {:ok, port}
      _other -> {:error, {:invalid, :port}}
    end
  end
end
