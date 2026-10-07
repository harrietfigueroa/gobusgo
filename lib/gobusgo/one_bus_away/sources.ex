defmodule Gobusgo.OneBusAway.Sources do
  @moduledoc """
  The OneBusAway sources that run on a schedule, as specs for
  `Gobusgo.Scheduler`. Everything here is pure: it builds the specs and starts
  nothing.

  Agency discovery records one response through
  `Gobusgo.OneBusAway.AgencyRecorder` once a minute. The vehicle source runs
  one `Gobusgo.OneBusAway.VehicleCycle` every five seconds, with a budget
  that ends before the run's deadline. The route source runs one
  `Gobusgo.OneBusAway.RouteCycle` every minute, which fetches the route data
  that is due and nothing when none is, with a budget that ends before the
  run's deadline. The arrival source runs one
  `Gobusgo.OneBusAway.ArrivalCycle` every five seconds, which fetches the
  arrivals of one open stop that is due, so the source makes at most one
  request every five seconds (decided in GOB-158).
  """

  alias Gobusgo.OneBusAway.AgencyRecorder
  alias Gobusgo.OneBusAway.ArrivalCycle
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.OneBusAway.RouteCycle
  alias Gobusgo.OneBusAway.VehicleCycle
  alias Gobusgo.Scheduler

  @agency_interval_ms 60_000
  @agency_deadline_ms 45_000
  @vehicle_interval_ms 5_000
  @vehicle_deadline_ms 4_500
  @vehicle_budget_ms 4_000
  @route_interval_ms 60_000
  @route_deadline_ms 55_000
  @route_budget_ms 50_000
  @arrival_interval_ms 5_000
  @arrival_deadline_ms 4_500
  @arrival_budget_ms 4_000
  @arrival_request_count_max 1

  @doc """
  Returns the spec of every source. `options[:agency_record_options]` are the
  options of `Gobusgo.OneBusAway.AgencyRecorder.record/2`,
  `options[:vehicle_cycle_options]` those of
  `Gobusgo.OneBusAway.VehicleCycle.run/2`,
  `options[:route_cycle_options]` those of
  `Gobusgo.OneBusAway.RouteCycle.run/2`, and
  `options[:arrival_cycle_options]` those of
  `Gobusgo.OneBusAway.ArrivalCycle.run/2`, each cycle's `:task_supervisor`
  among them.
  """
  @spec specs(Client.settings(), Keyword.t()) :: [Scheduler.spec()]
  def specs(%{base_url: base_url, api_key: api_key} = settings, options)
      when is_binary(base_url) and is_binary(api_key) and is_list(options) do
    options =
      Keyword.validate!(options, [
        :vehicle_cycle_options,
        :route_cycle_options,
        :arrival_cycle_options,
        agency_record_options: []
      ])

    agency_record_options = Keyword.fetch!(options, :agency_record_options)

    vehicle_cycle_options =
      Keyword.merge(
        [budget_ms: @vehicle_budget_ms],
        Keyword.fetch!(options, :vehicle_cycle_options)
      )

    route_cycle_options =
      Keyword.merge(
        [budget_ms: @route_budget_ms],
        Keyword.fetch!(options, :route_cycle_options)
      )

    arrival_cycle_options =
      Keyword.merge(
        [budget_ms: @arrival_budget_ms, request_count_max: @arrival_request_count_max],
        Keyword.fetch!(options, :arrival_cycle_options)
      )

    # The settings travel inside each function, which prints as an opaque
    # reference, so an inspected spec never shows the key.
    [
      %{
        name: Gobusgo.OneBusAway.AgencyScheduler,
        run: fn -> AgencyRecorder.record(settings, agency_record_options) end,
        interval_ms: @agency_interval_ms,
        deadline_ms: @agency_deadline_ms
      },
      %{
        name: Gobusgo.OneBusAway.VehicleScheduler,
        run: fn -> VehicleCycle.run(settings, vehicle_cycle_options) end,
        interval_ms: @vehicle_interval_ms,
        deadline_ms: @vehicle_deadline_ms
      },
      %{
        name: Gobusgo.OneBusAway.RouteScheduler,
        run: fn -> RouteCycle.run(settings, route_cycle_options) end,
        interval_ms: @route_interval_ms,
        deadline_ms: @route_deadline_ms
      },
      %{
        name: Gobusgo.OneBusAway.ArrivalScheduler,
        run: fn -> ArrivalCycle.run(settings, arrival_cycle_options) end,
        interval_ms: @arrival_interval_ms,
        deadline_ms: @arrival_deadline_ms
      }
    ]
  end
end
