defmodule Gobusgo.OneBusAway.Sources do
  @vehicle_interval_ms_min 5_000
  @vehicle_interval_ms_max 60_000
  @vehicle_hold_ms 60_000
  @tombstone_grace_interval_count_min 4

  @moduledoc """
  The OneBusAway sources that run on a schedule, as specs for
  `Gobusgo.Scheduler`. Everything here is pure: it builds the specs and starts
  nothing.

  Every source names its cadence as a policy of `Gobusgo.Cadence` with the
  function that returns the policy's signals, and a deadline under the
  policy's shortest interval, which `specs/2` asserts. Agency discovery,
  routes, and arrivals each name a fixed policy, which decides from no
  signals.

  The vehicle source names a steps policy of two steps: every
  #{@vehicle_interval_ms_max} ms with no viewer of vehicles, and every
  #{@vehicle_interval_ms_min} ms with one or more, which it keeps for
  #{@vehicle_hold_ms} ms after the last viewer leaves. Its signals function
  reads, on each call, the holders of
  `Gobusgo.OneBusAway.DemandKey.vehicles/0` in the demand registry `specs/2`
  is given, and exits when that registry does not answer. The policy's
  longest interval fits #{@tombstone_grace_interval_count_min} times into
  `Gobusgo.OneBusAway.VehicleView.State.tombstone_grace_ms/0`, which
  `specs/2` asserts with `assert_tombstone_grace/1`, so a vehicle is fetched
  that many times before its absence earns a tombstone.

  Agency discovery records one response through
  `Gobusgo.OneBusAway.AgencyRecorder` once a minute. The vehicle source runs
  one `Gobusgo.OneBusAway.VehicleCycle` per interval, with a budget
  that ends before the run's deadline. The route source runs one
  `Gobusgo.OneBusAway.RouteCycle` every minute, which fetches the route data
  that is due and nothing when none is, with a budget that ends before the
  run's deadline. The arrival source runs one
  `Gobusgo.OneBusAway.ArrivalCycle` every five seconds, which fetches the
  arrivals of one open stop that is due, so the source makes at most one
  request every five seconds (decided in GOB-158).

  The arrival cycle takes the age at which a stop is due again from
  `arrival_refresh_policy/0`, a proportional policy whose spacing is the
  time between two requests of the arrival source, so a stop is due again
  once every open stop has had its request: after 30 seconds for six open
  stops or fewer, five seconds more for each further stop, and five minutes
  from 60 open stops up.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Cadence
  alias Gobusgo.Demand
  alias Gobusgo.OneBusAway.AgencyRecorder
  alias Gobusgo.OneBusAway.ArrivalCycle
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.OneBusAway.DemandKey
  alias Gobusgo.OneBusAway.RouteCycle
  alias Gobusgo.OneBusAway.VehicleCycle
  alias Gobusgo.OneBusAway.VehicleView
  alias Gobusgo.Scheduler

  @agency_interval_ms 60_000
  @agency_deadline_ms 45_000
  @vehicle_deadline_ms 4_500
  @vehicle_budget_ms 4_000
  @route_interval_ms 60_000
  @route_deadline_ms 55_000
  @route_budget_ms 50_000
  @arrival_interval_ms 5_000
  @arrival_deadline_ms 4_500
  @arrival_budget_ms 4_000
  @arrival_request_count_max 1
  @arrival_refresh_age_ms_min 30_000
  @arrival_refresh_age_ms_max 300_000

  @doc """
  Returns `:ok` when `tombstone_grace_ms`, the time after which an absent
  vehicle gets a tombstone, spans at least
  #{@tombstone_grace_interval_count_min} times `interval_ms_max`, the
  longest time between two vehicle fetches, and raises an assertion error
  otherwise.
  """
  @spec assert_tombstone_grace(%{
          interval_ms_max: pos_integer(),
          tombstone_grace_ms: pos_integer()
        }) ::
          :ok
  def assert_tombstone_grace(%{
        interval_ms_max: interval_ms_max,
        tombstone_grace_ms: tombstone_grace_ms
      })
      when is_integer(interval_ms_max) and is_integer(tombstone_grace_ms) do
    Assert.condition(interval_ms_max >= 1, "interval_ms_max must be positive")

    Assert.condition(
      interval_ms_max * @tombstone_grace_interval_count_min <= tombstone_grace_ms,
      "the tombstone grace period of #{tombstone_grace_ms} ms must span " <>
        "#{@tombstone_grace_interval_count_min} intervals of #{interval_ms_max} ms"
    )
  end

  @doc """
  Returns the spec of every source. `options[:demand]` is the demand
  registry the vehicle source's signals function reads, a name or a pid,
  which need not be running. `options[:agency_record_options]` are the
  options of `Gobusgo.OneBusAway.AgencyRecorder.record/2`,
  `options[:vehicle_cycle_options]` those of
  `Gobusgo.OneBusAway.VehicleCycle.run/2`,
  `options[:route_cycle_options]` those of
  `Gobusgo.OneBusAway.RouteCycle.run/2`, and
  `options[:arrival_cycle_options]` those of
  `Gobusgo.OneBusAway.ArrivalCycle.run/2`, each cycle's `:task_supervisor`
  among them. Every spec passes `Gobusgo.Scheduler.assert_spec/1`.
  """
  @spec specs(Client.settings(), Keyword.t()) :: [Scheduler.spec()]
  def specs(%{base_url: base_url, api_key: api_key} = settings, options)
      when is_binary(base_url) and is_binary(api_key) and is_list(options) do
    options =
      Keyword.validate!(options, [
        :demand,
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
        [
          budget_ms: @arrival_budget_ms,
          request_count_max: @arrival_request_count_max,
          refresh_policy: arrival_refresh_policy()
        ],
        Keyword.fetch!(options, :arrival_cycle_options)
      )

    # The settings travel inside each function, which prints as an opaque
    # reference, so an inspected spec never shows the key.
    specs = [
      %{
        name: Gobusgo.OneBusAway.AgencyScheduler,
        run: fn -> AgencyRecorder.record(settings, agency_record_options) end,
        cadence: fixed_cadence(@agency_interval_ms),
        deadline_ms: @agency_deadline_ms
      },
      %{
        name: Gobusgo.OneBusAway.VehicleScheduler,
        run: fn -> VehicleCycle.run(settings, vehicle_cycle_options) end,
        cadence: vehicle_cadence(Keyword.fetch!(options, :demand)),
        deadline_ms: @vehicle_deadline_ms
      },
      %{
        name: Gobusgo.OneBusAway.RouteScheduler,
        run: fn -> RouteCycle.run(settings, route_cycle_options) end,
        cadence: fixed_cadence(@route_interval_ms),
        deadline_ms: @route_deadline_ms
      },
      %{
        name: Gobusgo.OneBusAway.ArrivalScheduler,
        run: fn -> ArrivalCycle.run(settings, arrival_cycle_options) end,
        cadence: fixed_cadence(@arrival_interval_ms),
        deadline_ms: @arrival_deadline_ms
      }
    ]

    Enum.each(specs, &Scheduler.assert_spec/1)
    specs
  end

  @doc """
  Returns the `Gobusgo.Cadence` policy that decides the age at which an open
  stop's arrivals are fetched again, from the signal `:item_count`, the
  count of open stops. Its spacing is the arrival source's interval divided
  by the requests one run of it makes, and its bounds are
  #{@arrival_refresh_age_ms_min} and #{@arrival_refresh_age_ms_max} ms.
  """
  @spec arrival_refresh_policy() :: Cadence.policy()
  def arrival_refresh_policy do
    request_spacing_ms = Integer.floor_div(@arrival_interval_ms, @arrival_request_count_max)

    Assert.condition(
      request_spacing_ms * @arrival_request_count_max == @arrival_interval_ms,
      "the arrival interval must hold a whole count of milliseconds for each request, " <>
        "got: #{@arrival_interval_ms} over #{@arrival_request_count_max}"
    )

    policy =
      {:proportional,
       %{
         interval_ms_min: @arrival_refresh_age_ms_min,
         interval_ms_max: @arrival_refresh_age_ms_max,
         item_spacing_ms: request_spacing_ms
       }}

    Cadence.assert_policy(policy)
    policy
  end

  defp vehicle_cadence(demand) do
    assert_tombstone_grace(%{
      interval_ms_max: @vehicle_interval_ms_max,
      tombstone_grace_ms: VehicleView.State.tombstone_grace_ms()
    })

    policy =
      {:steps,
       %{
         interval_ms_min: @vehicle_interval_ms_min,
         interval_ms_max: @vehicle_interval_ms_max,
         steps: [
           %{viewer_count_min: 0, interval_ms: @vehicle_interval_ms_max},
           %{viewer_count_min: 1, interval_ms: @vehicle_interval_ms_min}
         ],
         hold_ms: @vehicle_hold_ms
       }}

    signals = fn ->
      %{holder_count: holder_count, holder_absence_ms: holder_absence_ms} =
        Demand.holding(demand, DemandKey.vehicles())

      %{viewer_count: holder_count, viewer_absence_ms: holder_absence_ms}
    end

    %{policy: policy, signals: signals}
  end

  defp fixed_cadence(interval_ms) do
    %{policy: {:fixed, interval_ms}, signals: &no_signals/0}
  end

  defp no_signals, do: %{}
end
