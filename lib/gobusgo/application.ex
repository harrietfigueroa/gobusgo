defmodule Gobusgo.Application do
  @moduledoc false
  use Application

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Config
  alias Gobusgo.Demand
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.ArrivalBatch
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.DemandKey
  alias Gobusgo.OneBusAway.RequestGate
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RoutePathBatch
  alias Gobusgo.OneBusAway.Sources
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.OneBusAway.VehicleView
  alias Gobusgo.Scheduler

  @ingestion_task_count_max 8
  @restart_count_max 3
  @restart_window_seconds 5

  # 48 random bytes encode to the 64 characters a session secret needs.
  @generated_secret_byte_count 48

  # The two route views are fetch views under these names: the routes of
  # each agency, and the paths of each route.
  @route_view Gobusgo.OneBusAway.RouteView
  @route_path_view Gobusgo.OneBusAway.RoutePathView
  @route_view_agency_count_max 64
  @route_path_view_route_count_max 5_000

  # The stop view holds the stops of as many routes as the path view holds
  # paths. The 391 routes of 2026-10-05 reference 13,026 stops.
  @stop_view_stop_count_max 100_000

  # The arrivals view is a fetch view of the arrivals at each stop. A
  # response covers the 35 minutes after its fetch, so a fetch is of no use
  # five minutes after that.
  @arrival_view Gobusgo.OneBusAway.ArrivalView
  @arrival_view_stop_count_max 2_000
  @arrival_view_fetch_age_ms_max 40 * 60 * 1_000

  @impl Application
  def start(_type, _args) do
    with {:ok, %{ip: ip, port: port}} <- Config.http(),
         {:ok, configured_secret} <- Config.secret_key_base(),
         {:ok, %{scheduled: scheduled}} <- Config.ingestion(),
         {:ok, _basemap} <- Config.basemap() do
      # A scheduler starts its runs under the task supervisor, so the task
      # supervisor starts before the schedulers and stops after them. Every
      # run's requests take their permits from the gate, which starts first.
      children =
        [
          {Phoenix.PubSub, name: Gobusgo.PubSub},
          {AgencyView, name: AgencyView, pubsub: Gobusgo.PubSub},
          {VehicleView, name: VehicleView, pubsub: Gobusgo.PubSub},
          {FetchView,
           name: @route_view,
           pubsub: Gobusgo.PubSub,
           records: RouteBatch.Records,
           id_count_max: @route_view_agency_count_max},
          {FetchView,
           name: @route_path_view,
           pubsub: Gobusgo.PubSub,
           records: RoutePathBatch.Records,
           id_count_max: @route_path_view_route_count_max},
          {StopView,
           name: StopView,
           pubsub: Gobusgo.PubSub,
           route_count_max: @route_path_view_route_count_max,
           stop_count_max: @stop_view_stop_count_max},
          {FetchView,
           name: @arrival_view,
           pubsub: Gobusgo.PubSub,
           records: ArrivalBatch.Records,
           id_count_max: @arrival_view_stop_count_max,
           fetch_age_ms_max: @arrival_view_fetch_age_ms_max},
          {Demand, name: Demand, datasets: DemandKey.datasets()},
          {RequestGate, name: RequestGate},
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
        Sources.specs(settings,
          demand: Demand,
          vehicle_cycle_options: [task_supervisor: Gobusgo.IngestionTaskSupervisor],
          route_cycle_options: [task_supervisor: Gobusgo.IngestionTaskSupervisor],
          arrival_cycle_options: [task_supervisor: Gobusgo.IngestionTaskSupervisor]
        )

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
