defmodule Gobusgo.Application do
  @moduledoc false
  use Application

  alias Gobusgo.Config
  alias Gobusgo.OneBusAway.AgencyView

  @restart_count_max 3
  @restart_window_seconds 5

  # 48 random bytes encode to the 64 characters a session secret needs.
  @generated_secret_byte_count 48

  @impl Application
  def start(_type, _args) do
    with {:ok, %{ip: ip, port: port}} <- Config.http(),
         {:ok, configured_secret} <- Config.secret_key_base() do
      children = [
        {Phoenix.PubSub, name: Gobusgo.PubSub},
        {AgencyView, name: AgencyView},
        {GobusgoWeb.Endpoint,
         http: [ip: ip, port: port], secret_key_base: configured_secret || generate_secret()}
      ]

      Supervisor.start_link(children,
        strategy: :one_for_one,
        max_restarts: @restart_count_max,
        max_seconds: @restart_window_seconds,
        name: Gobusgo.Supervisor
      )
    else
      {:error, {:invalid, key}} -> {:error, {:invalid_setting, key}}
      {:error, {:missing, key}} -> {:error, {:missing_setting, key}}
    end
  end

  defp generate_secret do
    @generated_secret_byte_count |> :crypto.strong_rand_bytes() |> Base.encode64()
  end
end
