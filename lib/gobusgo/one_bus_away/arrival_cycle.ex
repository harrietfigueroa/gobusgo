defmodule Gobusgo.OneBusAway.ArrivalCycle do
  @budget_ms_default 4_000
  @fetch_retries_max 0
  @open_stop_count_max 2_000
  @request_count_max_default 1
  @request_deadline_ms_default 3_500
  @request_interval_ms_default 1_000
  @request_ms_min 250

  @moduledoc """
  One cycle of arrival fetches: records the arrivals of the open stops that
  are due, through `Gobusgo.OneBusAway.ArrivalRecorder`, one request after
  another at a fixed pace.

  The open stops are those of `Gobusgo.OneBusAway.OpenStops`, and
  `Gobusgo.OneBusAway.ArrivalSchedule` says which are due, from the fetch
  time each has in the arrivals view. A stop no process has open is never
  fetched, so what riders look at decides which stops a cycle may fetch and
  the cycle decides how many.

  A cycle takes at most `:request_count_max` due stops and leaves the rest
  to the next cycle. It starts one request every `:request_interval_ms` and
  starts none with less than #{@request_ms_min} ms of `:budget_ms` left, the
  least time in which a request is still worth starting. Each stop is
  recorded in a task of its own under the given task supervisor, so a stop
  whose fetch fails, raises, or stalls is one failed stop and the cycle goes
  on to the next. A fetch is not retried within a cycle, because the stop is
  still due in the next one. A cycle reads at most #{@open_stop_count_max}
  open stops.

  ## Results

    * `{:ok, counts}`: at least one stop is recorded, or nothing is due.
      `counts` holds `:open_count`, `:due_count`, `:recorded_count`,
      `:failed_count`, `:skipped_count`, the due stops the budget did not
      reach, `:deferred_count`, the due stops beyond `:request_count_max`,
      and `:unannounced_count`, the responses stored whose "response stored"
      event was not published.
    * `{:error, :nothing_recorded}`: stops are due, at least one was tried,
      and none is recorded.

  Each call logs once, with the counts and `failures`, the count of failed
  stops by cause, and no stop identifier: `debug`
  `OneBusAway arrival cycle found nothing due`, `info`
  `OneBusAway arrival cycle finished` when every stop tried is recorded and
  announced, `warning` `OneBusAway arrival cycle finished degraded` when
  some are, and `error` `OneBusAway arrival cycle failed` when none is.

  ## Options

    * `:task_supervisor` (required): the `Task.Supervisor` the stops run
      under.
    * `:stop_ids`: a zero-arity function returning the open stops. Defaults
      to those of `Gobusgo.OneBusAway.OpenStops`.
    * `:arrival_view`: the fetch view read. Defaults to
      `Gobusgo.OneBusAway.ArrivalView`.
    * `:clock`: returns the current UTC time. Defaults to
      `DateTime.utc_now/0`.
    * `:request_count_max`: defaults to #{@request_count_max_default}.
    * `:request_interval_ms`: defaults to #{@request_interval_ms_default}.
    * `:request_deadline_ms`: the bound on one stop. Defaults to
      #{@request_deadline_ms_default}.
    * `:budget_ms`: defaults to #{@budget_ms_default}.
    * `:sleep`: waits the given milliseconds between requests. Defaults to
      `Process.sleep/1`.
    * `:record_options`: options for the recorder's `record/2`.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.ArrivalRecorder
  alias Gobusgo.OneBusAway.ArrivalSchedule
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.OpenStops

  @type counts :: %{
          open_count: non_neg_integer(),
          due_count: non_neg_integer(),
          recorded_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          skipped_count: non_neg_integer(),
          deferred_count: non_neg_integer(),
          unannounced_count: non_neg_integer()
        }

  @doc "Records the arrivals of the open stops that are due, at most one slice of them."
  @spec run(Client.settings(), Keyword.t()) :: {:ok, counts()} | {:error, :nothing_recorded}
  def run(%{api_key: api_key} = settings, options) when is_binary(api_key) and is_list(options) do
    options =
      Keyword.validate!(options, [
        :task_supervisor,
        stop_ids: &open_stop_ids/0,
        arrival_view: Gobusgo.OneBusAway.ArrivalView,
        clock: &DateTime.utc_now/0,
        request_count_max: @request_count_max_default,
        request_interval_ms: @request_interval_ms_default,
        request_deadline_ms: @request_deadline_ms_default,
        budget_ms: @budget_ms_default,
        sleep: &Process.sleep/1,
        record_options: []
      ])

    for key <- [:request_count_max, :request_deadline_ms, :budget_ms] do
      value = Keyword.fetch!(options, key)
      Assert.condition(value > 0, "#{key} must be positive, got: #{value}")
    end

    interval_ms = Keyword.fetch!(options, :request_interval_ms)
    Assert.condition(interval_ms >= 0, "request_interval_ms must be zero or more")

    stop_ids = Keyword.fetch!(options, :stop_ids).()
    open_count = length(stop_ids)

    Assert.condition(
      open_count <= @open_stop_count_max,
      "a cycle reads at most #{@open_stop_count_max} open stops, got: #{open_count}"
    )

    due =
      ArrivalSchedule.due(%{
        stop_ids: stop_ids,
        fetch_times: FetchView.fetch_times(Keyword.fetch!(options, :arrival_view)),
        now: Keyword.fetch!(options, :clock).()
      })

    {taken, deferred} = Enum.split(due, Keyword.fetch!(options, :request_count_max))
    outcomes = record_each(settings, taken, options)
    Assert.condition(length(outcomes) == length(taken), "every stop taken must have an outcome")

    counts =
      counts(outcomes, %{
        open_count: open_count,
        due_count: length(due),
        deferred_count: length(deferred)
      })

    log(counts, failures(outcomes))

    if counts.failed_count >= 1 and counts.recorded_count == 0 do
      {:error, :nothing_recorded}
    else
      {:ok, counts}
    end
  end

  defp open_stop_ids, do: OpenStops.stop_ids(OpenStops)

  defp record_each(settings, stop_ids, options) do
    budget_end_ms = System.monotonic_time(:millisecond) + Keyword.fetch!(options, :budget_ms)
    interval_ms = Keyword.fetch!(options, :request_interval_ms)
    request_deadline_ms = Keyword.fetch!(options, :request_deadline_ms)
    sleep = Keyword.fetch!(options, :sleep)

    {outcomes, _next_start_ms} =
      Enum.map_reduce(stop_ids, System.monotonic_time(:millisecond), fn stop_id, next_start_ms ->
        wait_ms = next_start_ms - System.monotonic_time(:millisecond)
        if wait_ms > 0, do: sleep.(wait_ms)
        started_ms = System.monotonic_time(:millisecond)
        left_ms = budget_end_ms - started_ms

        outcome =
          if left_ms >= @request_ms_min do
            record(settings, stop_id, min(left_ms, request_deadline_ms), options)
          else
            :skipped
          end

        {outcome, started_ms + interval_ms}
      end)

    outcomes
  end

  defp record(settings, stop_id, deadline_ms, options) do
    record_options = Keyword.fetch!(options, :record_options)

    fetch_options =
      Keyword.merge(
        [max_retries: @fetch_retries_max, deadline_ms: deadline_ms],
        Keyword.get(record_options, :fetch_options, [])
      )

    record_options = Keyword.put(record_options, :fetch_options, fetch_options)

    task =
      options
      |> Keyword.fetch!(:task_supervisor)
      |> Task.Supervisor.async_nolink(fn ->
        ArrivalRecorder.record(settings, Keyword.put(record_options, :stop_id, stop_id))
      end)

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

  defp counts(outcomes, %{open_count: open_count, due_count: due_count} = found) do
    recorded_count = Enum.count(outcomes, &(&1 in [:recorded, :unannounced]))
    skipped_count = Enum.count(outcomes, &(&1 == :skipped))

    %{
      open_count: open_count,
      due_count: due_count,
      recorded_count: recorded_count,
      failed_count: length(outcomes) - recorded_count - skipped_count,
      skipped_count: skipped_count,
      deferred_count: found.deferred_count,
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
      counts.due_count == 0 ->
        Logger.debug("OneBusAway arrival cycle found nothing due", properties)

      degraded_count == 0 ->
        Logger.info("OneBusAway arrival cycle finished", properties)

      counts.recorded_count >= 1 or counts.failed_count == 0 ->
        Logger.warning("OneBusAway arrival cycle finished degraded", properties)

      true ->
        Logger.error("OneBusAway arrival cycle failed", properties)
    end
  end
end
