defmodule Gobusgo.Gbfs.VehicleStatusCycle do
  @run_deadline_ms 45_000

  @moduledoc """
  The scheduler source that fetches the shared vehicles of every GBFS system
  while a page shows them, and one run of it.

  ## Cadence

  `spec/2` names an on-demand policy of `Gobusgo.Cadence` over the holders of
  `Gobusgo.Gbfs.DemandKey.shared_vehicles/0` in the demand registry: the
  source is paused, and makes no request, while no process holds the key,
  and runs once per the configured interval while one or more do, for every
  viewer together. A scheduler starts a paused source's first run on the
  first tick after a viewer arrives when the interval has elapsed since the
  last run started, and always after a start, so the first viewer after a
  quiet period gets a fetch at once when the newest is older than the
  interval. The run's deadline is #{@run_deadline_ms} ms, under the shortest
  interval `Gobusgo.Config.fetch_shared_vehicles/1` accepts.

  ## A run

  `run/1` records each system of `Gobusgo.Gbfs.Systems.all/0` one after
  another through `Gobusgo.Gbfs.VehicleStatusRecorder`, and logs each
  outcome:

    * `info` `Shared vehicles recorded`, with the system, the version, the
      count of vehicles, and the request.
    * `warning` `Shared vehicle feed not published`, with the system and the
      versions passed over, once: when the view's entry for the system is
      not already a feed found not published. A feed that is gone needs
      someone to look at the integration, and the next runs that find it
      gone log nothing.
    * `error` `Shared vehicles not recorded`, with the system and the stage
      and cause of the failure.

  It returns `{:ok, counts}` when no system failed and `{:error, counts}`
  otherwise, with `:recorded_count`, `:not_published_count`, and
  `:failed_count`.

  ## Options

    * `:view`: the `Gobusgo.Gbfs.VehicleStatusView` whose entries decide the
      once-only log.
    * `:record_options`: options for
      `Gobusgo.Gbfs.VehicleStatusRecorder.record/2`.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Demand
  alias Gobusgo.Gbfs.DemandKey
  alias Gobusgo.Gbfs.Systems
  alias Gobusgo.Gbfs.VehicleStatusRecorder
  alias Gobusgo.Gbfs.VehicleStatusView
  alias Gobusgo.Scheduler

  @type counts :: %{
          recorded_count: non_neg_integer(),
          not_published_count: non_neg_integer(),
          failed_count: non_neg_integer()
        }

  @doc """
  The spec of the shared vehicle source, fetching every `interval_ms` while
  a process holds the shared vehicles key in the registry
  `options[:demand]`, a name or a pid. `options[:cycle_options]` are the
  options of `run/1`. The spec passes `Gobusgo.Scheduler.assert_spec/1`.
  """
  @spec spec(%{interval_ms: pos_integer()}, Keyword.t()) :: Scheduler.spec()
  def spec(%{interval_ms: interval_ms}, options) when is_list(options) do
    options = Keyword.validate!(options, [:demand, :cycle_options])
    demand = Keyword.fetch!(options, :demand)
    cycle_options = Keyword.fetch!(options, :cycle_options)

    Assert.condition(
      VehicleStatusRecorder.fetch_deadline_ms() < @run_deadline_ms,
      "a fetch must end inside the run's deadline"
    )

    spec = %{
      name: Gobusgo.Gbfs.VehicleStatusScheduler,
      run: fn -> run(cycle_options) end,
      cadence: %{
        policy: {:on_demand, %{interval_ms: interval_ms}},
        signals: fn ->
          %{viewer_count: Demand.holder_count(demand, DemandKey.shared_vehicles())}
        end
      },
      deadline_ms: @run_deadline_ms
    }

    Scheduler.assert_spec(spec)
    spec
  end

  @doc "Records the shared vehicles of every system once."
  @spec run(Keyword.t()) :: {:ok, counts()} | {:error, counts()}
  def run(options) when is_list(options) do
    options = Keyword.validate!(options, [:view, record_options: []])
    view = Keyword.fetch!(options, :view)
    Assert.condition(is_atom(view), "view must be an atom, got: #{inspect(view)}")
    record_options = Keyword.fetch!(options, :record_options)
    counts = %{recorded_count: 0, not_published_count: 0, failed_count: 0}

    counts =
      Enum.reduce(Systems.all(), counts, fn system, counts ->
        entry_before = VehicleStatusView.current(view, system.id)
        outcome = VehicleStatusRecorder.record(system, record_options)
        log(%{system_id: system.id, outcome: outcome, entry_before: entry_before})
        count(counts, outcome)
      end)

    if counts.failed_count == 0 do
      {:ok, counts}
    else
      {:error, counts}
    end
  end

  defp count(counts, {:ok, %{kind: :recorded}}),
    do: %{counts | recorded_count: counts.recorded_count + 1}

  defp count(counts, {:ok, %{kind: :not_published}}),
    do: %{counts | not_published_count: counts.not_published_count + 1}

  defp count(counts, {:error, _reason}), do: %{counts | failed_count: counts.failed_count + 1}

  defp log(%{outcome: {:ok, %{kind: :recorded} = recorded}}) do
    Logger.info("Shared vehicles recorded",
      system_id: recorded.system_id,
      version: recorded.version,
      vehicle_count: recorded.vehicle_count,
      request_id: recorded.request_id
    )
  end

  defp log(%{outcome: {:ok, %{kind: :not_published}}, entry_before: %{kind: :not_published}}),
    do: :ok

  defp log(%{outcome: {:ok, %{kind: :not_published} = found}}) do
    Logger.warning("Shared vehicle feed not published",
      system_id: found.system_id,
      passed_over: inspect(found.passed_over)
    )
  end

  defp log(%{system_id: system_id, outcome: {:error, {stage, cause}}}) do
    Logger.error("Shared vehicles not recorded",
      system_id: system_id,
      stage: stage,
      cause: inspect(cause)
    )
  end
end
