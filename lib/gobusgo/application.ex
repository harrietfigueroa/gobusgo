defmodule Gobusgo.Application do
  @moduledoc false
  use Application

  alias Gobusgo.Config

  @restart_count_max 3
  @restart_window_seconds 5

  @impl Application
  def start(_type, _args) do
    case Config.http() do
      {:ok, %{ip: ip, port: port}} ->
        children = [{GobusgoWeb.Endpoint, http: [ip: ip, port: port]}]

        Supervisor.start_link(children,
          strategy: :one_for_one,
          max_restarts: @restart_count_max,
          max_seconds: @restart_window_seconds,
          name: Gobusgo.Supervisor
        )

      {:error, {:invalid, key}} ->
        {:error, {:invalid_http_setting, key}}
    end
  end
end
