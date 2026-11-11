defmodule Gobusgo.Application do
  @moduledoc false
  use Application

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Config
  alias Gobusgo.Demand
  alias Gobusgo.Gbfs.VehicleStatusCycle
  alias Gobusgo.Gbfs.VehicleStatusRetention
  alias Gobusgo.Gbfs.VehicleStatusView
  alias Gobusgo.Gbfs.VehicleTiles
  alias Gobusgo.Gbfs.VehicleTypeRecords
  alias Gobusgo.Gbfs.VehicleTypesCycle
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.ArrivalBatch
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.DemandKey
  alias Gobusgo.OneBusAway.RequestGate
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RoutePathBatch
  alias Gobusgo.OneBusAway.RouteRebuild
  alias Gobusgo.OneBusAway.RouteScheduleRebuild
  alias Gobusgo.OneBusAway.RouteScheduleView
  alias Gobusgo.OneBusAway.Sources
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.OneBusAway.TripPathCache
  alias Gobusgo.OneBusAway.TripPathsServed
  alias Gobusgo.OneBusAway.VehicleBatch
  alias Gobusgo.OneBusAway.VehicleView
  alias Gobusgo.RetentionPolicy
  alias Gobusgo.S3.Credentials
  alias Gobusgo.Scheduler
  alias Gobusgo.Usage

  @ingestion_task_count_max 13
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

  # The situation views are fetch views of the situations each response
  # references: those of each agency's vehicle fetch, and those of each
  # stop's arrivals fetch, which leave with the arrivals they came with.
  @vehicle_situation_view Gobusgo.OneBusAway.VehicleSituationView
  @vehicle_situation_view_agency_count_max 64
  @arrival_situation_view Gobusgo.OneBusAway.ArrivalSituationView

  # The trip path cache holds the paths of 2,000 trips, which 2,000 King
  # County Metro paths of 2026-11-09 fill with 1.2 MiB of table and 2.3 MiB
  # of path text. Two builds run at once, each capped at its own heap.
  @trip_path_cache_trip_count_max 2_000
  @trip_path_builder_count_max 2

  # The shared vehicle view holds the newest fetch of each GBFS system.
  @vehicle_status_view_system_count_max 8
  # The vehicle type view is a fetch view of each GBFS system's vehicle
  # types at each version that publishes them.
  @vehicle_type_view Gobusgo.Gbfs.VehicleTypeView
  @vehicle_type_view_id_count_max 32

  @impl Application
  def start(_type, _args) do
    with {:ok, %{ip: ip, port: port}} <- Config.http(),
         {:ok, configured_secret} <- Config.secret_key_base(),
         {:ok, public_host} <- Config.public_host(),
         {:ok, %{scheduled: scheduled}} <- Config.ingestion(),
         {:ok, %{recorded: recorded}} <- Config.usage(),
         {:ok, shared_vehicles} <- Config.shared_vehicles(),
         {:ok, _vehicle_motion} <- Config.vehicle_motion(),
         {:ok, storage} <- Config.storage(),
         {:ok, _basemap} <- Config.basemap(),
         {:ok, _tiles} <- Config.tiles(),
         {:ok, _routing} <- Config.routing(),
         {:ok, _shared_vehicle_tiles} <- Config.shared_vehicle_tiles(),
         {:ok, _revision} <- Config.revision(),
         {:ok, _donation_url} <- Config.donation_url() do
      # The count of served path requests starts before any page can serve one.
      :ok = TripPathsServed.init()

      # A scheduler starts its runs under the task supervisor, so the task
      # supervisor starts before the schedulers and stops after them. Every
      # run's requests take their permits from the gate, which starts first.
      # The rebuild fills the route views before the first route cycle reads
      # them, and the endpoint starts before it, so the health check answers
      # while it runs.
      children =
        [{Phoenix.PubSub, name: Gobusgo.PubSub}] ++
          storage_children(storage) ++
          [
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
            {RouteScheduleView,
             name: RouteScheduleView, route_count_max: @route_path_view_route_count_max},
            {TripPathCache, name: TripPathCache, trip_count_max: @trip_path_cache_trip_count_max},
            {Task.Supervisor,
             name: Gobusgo.OneBusAway.TripPathBuilders, max_children: @trip_path_builder_count_max},
            {FetchView,
             name: @arrival_view,
             pubsub: Gobusgo.PubSub,
             records: ArrivalBatch.Records,
             id_count_max: @arrival_view_stop_count_max,
             fetch_age_ms_max: @arrival_view_fetch_age_ms_max},
            {FetchView,
             name: @vehicle_situation_view,
             pubsub: Gobusgo.PubSub,
             records: VehicleBatch.SituationRecords,
             id_count_max: @vehicle_situation_view_agency_count_max},
            {FetchView,
             name: @arrival_situation_view,
             pubsub: Gobusgo.PubSub,
             records: ArrivalBatch.SituationRecords,
             id_count_max: @arrival_view_stop_count_max,
             fetch_age_ms_max: @arrival_view_fetch_age_ms_max},
            {VehicleStatusView,
             name: VehicleStatusView,
             pubsub: Gobusgo.PubSub,
             system_count_max: @vehicle_status_view_system_count_max},
            {FetchView,
             name: @vehicle_type_view,
             pubsub: Gobusgo.PubSub,
             records: VehicleTypeRecords,
             id_count_max: @vehicle_type_view_id_count_max},
            {VehicleTiles, name: VehicleTiles, pubsub: Gobusgo.PubSub},
            {Demand,
             name: Demand,
             datasets: DemandKey.datasets() ++ Gobusgo.Gbfs.DemandKey.datasets(),
             holder_item_count_max: GobusgoWeb.VehicleLive.OpenStops.open_count_max()}
          ] ++
          usage_children(recorded) ++
          [
            {RequestGate, name: RequestGate},
            {Task.Supervisor,
             name: Gobusgo.IngestionTaskSupervisor, max_children: @ingestion_task_count_max},
            {GobusgoWeb.RouteStopTiles, name: GobusgoWeb.RouteStopTiles},
            {Gobusgo.Routing.Snapshots, name: Gobusgo.Routing.Snapshots},
            {Gobusgo.Addresses, name: Gobusgo.Addresses},
            {GobusgoWeb.Endpoint,
             [http: [ip: ip, port: port], secret_key_base: configured_secret || generate_secret()] ++
               GobusgoWeb.PublicHost.endpoint_options(public_host)}
          ] ++
          rebuild_children(scheduled) ++
          [
            scheduler_supervisor(
              source_specs(scheduled) ++
                gbfs_specs(scheduled, shared_vehicles) ++
                tile_specs(scheduled) ++
                routing_specs(scheduled) ++
                address_specs(scheduled) ++
                trip_paths_specs(scheduled) ++ cleanup_specs(scheduled, storage)
            )
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

  # The credentials start before everything that stores and stop after it:
  # the usage recorder writes its last file as it shuts down.
  defp storage_children(:local), do: []

  defp storage_children(%{credentials: source}) do
    [{Credentials, name: Credentials, source: source}]
  end

  # The views are rebuilt wherever the sources are scheduled, from whatever
  # the reader holds.
  defp rebuild_children(true) do
    [
      {RouteRebuild, task_supervisor: Gobusgo.IngestionTaskSupervisor},
      {RouteScheduleRebuild, task_supervisor: Gobusgo.IngestionTaskSupervisor}
    ]
  end

  defp rebuild_children(false), do: []

  # The recorder starts before the endpoint and stops after it, so the
  # connections the endpoint's shutdown ends are in the recorder's last file.
  defp usage_children(true), do: [{Usage, name: Usage}]
  defp usage_children(false), do: []

  defp generate_secret do
    @generated_secret_byte_count |> :crypto.strong_rand_bytes() |> Base.encode64()
  end

  # The cleanup of stored content runs wherever the sources are scheduled
  # and the content is in local files, with or without the OneBusAway
  # settings. A bucket expires its own objects by its lifecycle rules.
  defp cleanup_specs(true, :local), do: [RetentionPolicy.cleanup_spec([])]
  defp cleanup_specs(true, %{bucket: _bucket}), do: []
  defp cleanup_specs(false, _storage), do: []

  # The tile archive is built from the route views wherever the sources are
  # scheduled, which is where the views are filled.
  defp tile_specs(true), do: [GobusgoWeb.RouteStopTiles.spec(server: GobusgoWeb.RouteStopTiles)]
  defp tile_specs(false), do: []

  # The routing snapshots are built from the schedule view wherever the
  # sources are scheduled, which is where the view is filled.
  defp routing_specs(true),
    do: [Gobusgo.Routing.Snapshots.spec(server: Gobusgo.Routing.Snapshots)]

  defp routing_specs(false), do: []

  # The count of served path requests is logged wherever the sources are
  # scheduled, which is where a node serves pages.
  defp trip_paths_specs(true), do: [TripPathsServed.log_spec()]
  defp trip_paths_specs(false), do: []
  # The address shards are built wherever the sources are scheduled. The
  # county's export is a public download, so the build needs no setting.
  defp address_specs(true), do: [Gobusgo.Addresses.spec(server: Gobusgo.Addresses)]
  defp address_specs(false), do: []

  # The GBFS feeds are public, so their sources need no settings and run
  # wherever the sources are scheduled. The retention source deletes the
  # stored shared vehicle files whether or not the shared vehicle source
  # runs.
  defp gbfs_specs(true, shared_vehicles) do
    [
      VehicleTypesCycle.spec([]),
      VehicleStatusCycle.spec(shared_vehicles,
        demand: Demand,
        cycle_options: [view: VehicleStatusView, tile_options: [server: VehicleTiles]]
      ),
      VehicleStatusRetention.spec([])
    ]
  end

  defp gbfs_specs(false, _shared_vehicles), do: []

  defp source_specs(false), do: []

  defp source_specs(true) do
    case Config.one_bus_away() do
      {:ok, settings} ->
        Sources.specs(settings,
          demand: Demand,
          vehicle_cycle_options: [task_supervisor: Gobusgo.IngestionTaskSupervisor],
          route_cycle_options: [task_supervisor: Gobusgo.IngestionTaskSupervisor],
          route_schedule_cycle_options: [task_supervisor: Gobusgo.IngestionTaskSupervisor],
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
