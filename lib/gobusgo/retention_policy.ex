defmodule Gobusgo.RetentionPolicy do
  @vehicle_day_count 7
  @arrival_day_count 7
  @agency_day_count 30
  @route_day_count 30
  @route_path_day_count 30
  @schedule_lead_day_count 2
  @route_schedule_day_count @vehicle_day_count + @schedule_lead_day_count
  @usage_day_count 3
  @route_stop_tiles_day_count 2
  @routing_snapshot_day_count 2
  @shared_vehicle_day_count 1
  @address_day_count 7
  @pace_day_count 30
  @cleanup_interval_ms 3_600_000
  @cleanup_deadline_ms 600_000

  @moduledoc """
  How long the application keeps each dataset it stores, and the spec of the
  scheduled cleanup that applies it.

  Each dataset has one rule of `Gobusgo.Retention`, by the prefix its owner
  names:

    * the vehicles of an agency, #{@vehicle_day_count} days, a week of
      fetches to replay against the schedules they ran on;
    * the arrivals at a stop, #{@arrival_day_count} days, OneBusAway's own
      predictions for the stops a vehicle page or an MCP `arrivals` call
      holds open, kept a week as a baseline for vehicle-prediction research;
    * the agencies, #{@agency_day_count} days;
    * the routes of an agency, #{@route_day_count} days;
    * the stops and paths of a route, #{@route_path_day_count} days;
    * the schedule of a route on a service date, #{@route_schedule_day_count}
      days, the vehicles' days and #{@schedule_lead_day_count} more: a
      service date's schedule is fetched on the UTC date before it at the
      earliest, and the vehicles of a UTC date run on that date's service
      date and the one before, so each stored vehicle fetch keeps the
      schedules of its trips. The days hold the fetch dates of the three
      service dates the schedule view holds, so a start rebuilds them;
    * the usage records of page connections, #{@usage_day_count} days.
    * the route and stop tile archives, #{@route_stop_tiles_day_count} days,
      longer than a page that loaded an archive stays open;
    * the routing snapshot files, #{@routing_snapshot_day_count} days, longer
      than a file the manifest names goes unwritten, since a build writes
      every file again each day.
    * the shared vehicle files of a GBFS system,
      #{@shared_vehicle_day_count} day, a backstop:
      `Gobusgo.Gbfs.VehicleStatusRetention` deletes each within ten minutes
      of its fetch. The files that publish a fetch to the browser have the
      same backstop and are deleted with their fetch.
    * the address shard files and their manifests, #{@address_day_count}
      days, longer than a file the manifest names goes unwritten, since a
      build writes every file again each day it runs.
    * the daily pace tables, #{@pace_day_count} days.

  The places file and its manifest under `places/` have no rule: nothing
  deletes them, and an old file stays until it is removed by hand.

  The cleanup is one `Gobusgo.Cleanup.run/2` every #{@cleanup_interval_ms}
  ms, with #{@cleanup_deadline_ms} ms to finish.
  """

  alias Gobusgo.Cleanup
  alias Gobusgo.Gbfs.RawVehicleStatus
  alias Gobusgo.Gbfs.VehicleTileSet
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.OneBusAway.RawArrivalResponse
  alias Gobusgo.OneBusAway.RawRoutePathResponse
  alias Gobusgo.OneBusAway.RawRouteResponse
  alias Gobusgo.OneBusAway.RawRouteScheduleResponse
  alias Gobusgo.OneBusAway.RawVehicleResponse
  alias Gobusgo.Retention
  alias Gobusgo.Scheduler
  alias Gobusgo.Usage

  @doc "The rule of every stored dataset."
  @spec rules() :: [Retention.rule(), ...]
  def rules do
    rules = [
      %{prefix: RawVehicleResponse.destination_prefix(), day_count: @vehicle_day_count},
      %{prefix: RawArrivalResponse.destination_prefix(), day_count: @arrival_day_count},
      %{prefix: RawAgencyResponse.destination_prefix(), day_count: @agency_day_count},
      %{prefix: RawRouteResponse.destination_prefix(), day_count: @route_day_count},
      %{prefix: RawRoutePathResponse.destination_prefix(), day_count: @route_path_day_count},
      %{
        prefix: RawRouteScheduleResponse.destination_prefix(),
        day_count: @route_schedule_day_count
      },
      %{prefix: Usage.Records.prefix(), day_count: @usage_day_count},
      %{prefix: GobusgoWeb.RouteStopTiles.prefix(), day_count: @route_stop_tiles_day_count},
      %{prefix: Gobusgo.Routing.Snapshot.prefix(), day_count: @routing_snapshot_day_count},
      %{prefix: RawVehicleStatus.destination_prefix(), day_count: @shared_vehicle_day_count},
      %{prefix: VehicleTileSet.prefix(), day_count: @shared_vehicle_day_count},
      %{prefix: Gobusgo.Addresses.prefix(), day_count: @address_day_count},
      %{prefix: Gobusgo.Pace.Aggregate.prefix(), day_count: @pace_day_count}
    ]

    Enum.each(rules, &Retention.assert_rule/1)
    rules
  end

  @doc "The days a usage record is kept."
  @spec usage_day_count() :: pos_integer()
  def usage_day_count, do: @usage_day_count

  @doc "The days a route and stop tile archive is kept."
  @spec route_stop_tiles_day_count() :: pos_integer()
  def route_stop_tiles_day_count, do: @route_stop_tiles_day_count

  @doc """
  The spec of the scheduler that runs the cleanup. `options` are the options
  of `Gobusgo.Cleanup.run/2`. The spec passes `Gobusgo.Scheduler.assert_spec/1`.
  """
  @spec cleanup_spec(Keyword.t()) :: Scheduler.spec()
  def cleanup_spec(options) when is_list(options) do
    rules = rules()

    spec = %{
      name: Gobusgo.CleanupScheduler,
      run: fn -> Cleanup.run(rules, options) end,
      cadence: %{policy: {:fixed, @cleanup_interval_ms}, signals: &no_signals/0},
      deadline_ms: @cleanup_deadline_ms
    }

    Scheduler.assert_spec(spec)
    spec
  end

  defp no_signals, do: %{}
end
