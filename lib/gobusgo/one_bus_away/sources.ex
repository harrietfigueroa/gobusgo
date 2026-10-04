defmodule Gobusgo.OneBusAway.Sources do
  @moduledoc """
  The OneBusAway sources that run on a schedule, as specs for
  `Gobusgo.Scheduler`. Everything here is pure: it builds the specs and starts
  nothing.

  Agency discovery records one response through
  `Gobusgo.OneBusAway.AgencyRecorder` once a minute. The vehicle source runs
  one `Gobusgo.OneBusAway.VehicleCycle` every five seconds, with a budget
  that ends before the run's deadline.
  """

  alias Gobusgo.OneBusAway.AgencyRecorder
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.OneBusAway.VehicleCycle
  alias Gobusgo.Scheduler

  @agency_interval_ms 60_000
  @agency_deadline_ms 45_000
  @vehicle_interval_ms 5_000
  @vehicle_deadline_ms 4_500
  @vehicle_budget_ms 4_000

  @doc """
  Returns the spec of every source. `options[:agency_record_options]` are the
  options of `Gobusgo.OneBusAway.AgencyRecorder.record/2`, and
  `options[:vehicle_cycle_options]` those of
  `Gobusgo.OneBusAway.VehicleCycle.run/2`, its `:task_supervisor` among them.
  """
  @spec specs(Client.settings(), Keyword.t()) :: [Scheduler.spec()]
  def specs(%{base_url: base_url, api_key: api_key} = settings, options)
      when is_binary(base_url) and is_binary(api_key) and is_list(options) do
    options = Keyword.validate!(options, [:vehicle_cycle_options, agency_record_options: []])
    agency_record_options = Keyword.fetch!(options, :agency_record_options)

    vehicle_cycle_options =
      Keyword.merge(
        [budget_ms: @vehicle_budget_ms],
        Keyword.fetch!(options, :vehicle_cycle_options)
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
      }
    ]
  end
end
