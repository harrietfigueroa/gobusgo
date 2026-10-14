defmodule Gobusgo.RetentionPolicy do
  @vehicle_day_count 1
  @arrival_day_count 1
  @agency_day_count 30
  @route_day_count 30
  @route_path_day_count 30
  @usage_day_count 3
  @route_stop_tiles_day_count 2
  @cleanup_interval_ms 3_600_000
  @cleanup_deadline_ms 600_000

  @moduledoc """
  How long the application keeps each dataset it stores, and the spec of the
  scheduled cleanup that applies it.

  Each dataset has one rule of `Gobusgo.Retention`, by the prefix its owner
  names:

    * the vehicles of an agency, #{@vehicle_day_count} day;
    * the arrivals at a stop, #{@arrival_day_count} day;
    * the agencies, #{@agency_day_count} days;
    * the routes of an agency, #{@route_day_count} days;
    * the stops and paths of a route, #{@route_path_day_count} days;
    * the usage records of page connections, #{@usage_day_count} days.
    * the route and stop tile archives, #{@route_stop_tiles_day_count} days,
      longer than a page that loaded an archive stays open.

  The cleanup is one `Gobusgo.Cleanup.run/2` every #{@cleanup_interval_ms}
  ms, with #{@cleanup_deadline_ms} ms to finish.
  """

  alias Gobusgo.Cleanup
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.OneBusAway.RawArrivalResponse
  alias Gobusgo.OneBusAway.RawRoutePathResponse
  alias Gobusgo.OneBusAway.RawRouteResponse
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
      %{prefix: Usage.Records.prefix(), day_count: @usage_day_count},
      %{prefix: GobusgoWeb.RouteStopTiles.prefix(), day_count: @route_stop_tiles_day_count}
    ]

    Enum.each(rules, &Retention.assert_rule/1)
    rules
  end

  @doc "The days a usage record is kept."
  @spec usage_day_count() :: pos_integer()
  def usage_day_count, do: @usage_day_count

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
