defmodule Gobusgo.OneBusAway.VehicleCycle do
  @agency_count_max 64
  @agency_deadline_ms_default 4_000
  @budget_ms_default 9_000
  @fetch_retries_max 0

  @moduledoc """
  One cycle of vehicle fetches: records the vehicles of every agency of the
  agency view's current fetch through
  `Gobusgo.OneBusAway.VehicleRecorder`, one agency after another, in agency
  identifier order.

  Each agency is recorded in a task of its own under the given task
  supervisor, so an agency whose fetch fails, raises, or stalls is one failed
  agency and the cycle goes on to the next. An agency gets at most
  `:agency_deadline_ms`, and the cycle starts no agency once `:budget_ms` is
  spent: the agencies left are skipped and the next cycle fetches them. A
  fetch is not retried within a cycle, because the next cycle is its retry.
  A cycle takes at most #{@agency_count_max} agencies.

  ## Results

    * `{:ok, counts}`: at least one agency is recorded, or there is no agency
      to fetch. `counts` holds `:agency_count`, `:recorded_count`,
      `:failed_count`, `:skipped_count`, and `:unannounced_count`, the
      responses stored whose "response stored" event was not published.
    * `{:error, :nothing_recorded}`: there are agencies and none is recorded.

  Each call logs once: `info` `OneBusAway vehicle cycle finished` when every
  agency is recorded and announced, `warning`
  `OneBusAway vehicle cycle finished degraded` when some are, and `error`
  `OneBusAway vehicle cycle failed` when none is, each with the counts and
  `failures`, the count of failed agencies by cause.

  ## Options

    * `:task_supervisor` (required): the `Task.Supervisor` the agencies run
      under.
    * `:agency_ids`: a zero-arity function returning the agencies to fetch.
      Defaults to the agencies of the current fetch of
      `Gobusgo.OneBusAway.AgencyView`.
    * `:budget_ms`: defaults to #{@budget_ms_default}.
    * `:agency_deadline_ms`: defaults to #{@agency_deadline_ms_default}.
    * `:record_options`: options for
      `Gobusgo.OneBusAway.VehicleRecorder.record/2`.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.OneBusAway.VehicleRecorder

  @type counts :: %{
          agency_count: non_neg_integer(),
          recorded_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          skipped_count: non_neg_integer(),
          unannounced_count: non_neg_integer()
        }

  @doc "Records the vehicles of every agency once."
  @spec run(Client.settings(), Keyword.t()) :: {:ok, counts()} | {:error, :nothing_recorded}
  def run(%{api_key: api_key} = settings, options) when is_binary(api_key) and is_list(options) do
    options =
      Keyword.validate!(options, [
        :task_supervisor,
        agency_ids: &current_agency_ids/0,
        budget_ms: @budget_ms_default,
        agency_deadline_ms: @agency_deadline_ms_default,
        record_options: []
      ])

    budget_ms = Keyword.fetch!(options, :budget_ms)
    agency_deadline_ms = Keyword.fetch!(options, :agency_deadline_ms)
    Assert.condition(budget_ms > 0, "budget_ms must be positive, got: #{budget_ms}")

    Assert.condition(
      agency_deadline_ms > 0,
      "agency_deadline_ms must be positive, got: #{agency_deadline_ms}"
    )

    agency_ids = options |> Keyword.fetch!(:agency_ids) |> then(& &1.()) |> Enum.sort()
    agency_count = length(agency_ids)

    Assert.condition(
      agency_count <= @agency_count_max,
      "a cycle takes at most #{@agency_count_max} agencies, got: #{agency_count}"
    )

    budget_end_ms = System.monotonic_time(:millisecond) + budget_ms

    outcomes =
      Enum.map(agency_ids, fn agency_id ->
        left_ms = budget_end_ms - System.monotonic_time(:millisecond)

        if left_ms > 0 do
          record(settings, agency_id, min(left_ms, agency_deadline_ms), options)
        else
          :skipped
        end
      end)

    counts = counts(outcomes)
    Assert.condition(counts.agency_count == agency_count, "every agency must have an outcome")
    log(counts, failures(outcomes))

    if agency_count >= 1 and counts.recorded_count == 0 do
      {:error, :nothing_recorded}
    else
      {:ok, counts}
    end
  end

  defp current_agency_ids do
    case AgencyView.current(AgencyView) do
      nil -> []
      %{agency_ids: agency_ids} -> agency_ids
    end
  end

  defp record(settings, agency_id, deadline_ms, options) do
    record_options = Keyword.fetch!(options, :record_options)

    fetch_options =
      Keyword.merge(
        [max_retries: @fetch_retries_max, deadline_ms: deadline_ms],
        Keyword.get(record_options, :fetch_options, [])
      )

    record_options =
      Keyword.merge(record_options, agency_id: agency_id, fetch_options: fetch_options)

    task =
      options
      |> Keyword.fetch!(:task_supervisor)
      |> Task.Supervisor.async_nolink(fn -> VehicleRecorder.record(settings, record_options) end)

    case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{event_published: true}}} -> :recorded
      {:ok, {:ok, %{event_published: false}}} -> :unannounced
      {:ok, {:error, {stage, reason}}} -> {:failed, cause(stage, reason)}
      nil -> {:failed, "deadline_exceeded"}
      {:exit, _reason} -> {:failed, "crashed"}
    end
  end

  # The name of a failure without the terms it carries, so the causes of a
  # cycle group into few keys.
  defp cause(stage, reason) do
    name =
      case reason do
        name when is_atom(name) -> name
        {name, _detail} when is_atom(name) -> name
      end

    "#{stage}:#{name}"
  end

  defp counts(outcomes) do
    recorded_count = Enum.count(outcomes, &(&1 in [:recorded, :unannounced]))
    skipped_count = Enum.count(outcomes, &(&1 == :skipped))

    %{
      agency_count: length(outcomes),
      recorded_count: recorded_count,
      failed_count: length(outcomes) - recorded_count - skipped_count,
      skipped_count: skipped_count,
      unannounced_count: Enum.count(outcomes, &(&1 == :unannounced))
    }
  end

  defp failures(outcomes) do
    for({:failed, cause} <- outcomes, do: cause) |> Enum.frequencies()
  end

  defp log(counts, failures) do
    properties = Map.to_list(counts) ++ [failures: inspect(failures)]
    degraded_count = counts.failed_count + counts.skipped_count + counts.unannounced_count

    cond do
      degraded_count == 0 ->
        Logger.info("OneBusAway vehicle cycle finished", properties)

      counts.recorded_count >= 1 ->
        Logger.warning("OneBusAway vehicle cycle finished degraded", properties)

      true ->
        Logger.error("OneBusAway vehicle cycle failed", properties)
    end
  end
end
