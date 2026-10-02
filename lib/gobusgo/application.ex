defmodule Gobusgo.Application do
  @moduledoc false
  use Application

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Config
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.Sources
  alias Gobusgo.Scheduler

  @ingestion_task_count_max 8
  @restart_count_max 3
  @restart_window_seconds 5

  # 48 random bytes encode to the 64 characters a session secret needs.
  @generated_secret_byte_count 48

  @impl Application
  def start(_type, _args) do
    with {:ok, %{ip: ip, port: port}} <- Config.http(),
         {:ok, configured_secret} <- Config.secret_key_base(),
         {:ok, %{scheduled: scheduled}} <- Config.ingestion() do
      # A scheduler starts its runs under the task supervisor, so the task
      # supervisor starts before the schedulers and stops after them.
      children = [
        {Phoenix.PubSub, name: Gobusgo.PubSub},
        {AgencyView, name: AgencyView, pubsub: Gobusgo.PubSub},
        {Task.Supervisor,
         name: Gobusgo.IngestionTaskSupervisor, max_children: @ingestion_task_count_max},
        scheduler_supervisor(source_specs(scheduled)),
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

  defp source_specs(false), do: []

  defp source_specs(true) do
    case Config.one_bus_away() do
      {:ok, settings} ->
        Sources.specs(settings, [])

      {:error, {:missing, key}} ->
        Logger.warning("OneBusAway sources not scheduled", missing_setting: key)
        []
    end
  end

  defp scheduler_supervisor(specs) do
    # One run is in flight per source, so the sources fit the task supervisor.
    Assert.condition(
      length(specs) <= @ingestion_task_count_max,
      "at most #{@ingestion_task_count_max} sources, got: #{length(specs)}"
    )

    children =
      for spec <- specs do
        {Scheduler, spec: spec, task_supervisor: Gobusgo.IngestionTaskSupervisor}
      end

    %{
      id: Gobusgo.SchedulerSupervisor,
      type: :supervisor,
      start:
        {Supervisor, :start_link,
         [
           children,
           [
             strategy: :one_for_one,
             max_restarts: @restart_count_max,
             max_seconds: @restart_window_seconds,
             name: Gobusgo.SchedulerSupervisor
           ]
         ]}
    }
  end
end
