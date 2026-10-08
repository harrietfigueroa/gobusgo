defmodule GobusgoWeb.UsageHook do
  @live_suffix "_live"

  @moduledoc """
  The mount hook that registers a connected page with the usage recorder,
  `Gobusgo.Usage`, so every page of the live session it is attached to is
  recorded with no code of its own.

  The page's name is its LiveView module's last name in snake case, less
  `#{@live_suffix}`: `vehicle` for `GobusgoWeb.VehicleLive`. The facts come
  from `GobusgoWeb.ConnectionFacts`. The static render registers nothing.

  A page mounts whatever the recorder answers: one that refuses the
  connection or is not running leaves the page unrecorded, logged as
  `Page connection not recorded` at `debug` with the refusal.
  """

  import Phoenix.LiveView, only: [connected?: 1, get_connect_info: 2, get_connect_params: 1]

  require Logger

  alias Gobusgo.Usage
  alias GobusgoWeb.ConnectionFacts

  @recorder Usage

  @doc "The name a usage record gives the page of `view`, a LiveView module."
  @spec page(module()) :: String.t()
  def page(view) when is_atom(view) do
    view
    |> Module.split()
    |> List.last()
    |> Macro.underscore()
    |> String.replace_suffix(@live_suffix, "")
  end

  @doc "Registers a connected page's connection, and lets every page mount."
  def on_mount(:default, _params, _session, socket) do
    case connected?(socket) do
      true -> register(socket)
      false -> :ok
    end

    {:cont, socket}
  end

  defp register(socket) do
    connection =
      ConnectionFacts.from_connect(%{
        page: page(socket.view),
        connect_params: get_connect_params(socket),
        user_agent: get_connect_info(socket, :user_agent),
        host: host(get_connect_info(socket, :uri))
      })

    case Usage.register(@recorder, connection) do
      :ok -> :ok
      {:error, refusal} -> Logger.debug("Page connection not recorded", refusal: refusal)
    end
  end

  defp host(%URI{host: host}), do: host
  defp host(nil), do: nil
end
