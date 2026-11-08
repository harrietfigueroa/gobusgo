defmodule Gobusgo.OneBusAway.RouteScheduleCycle do
  @budget_ms_default 50_000
  @fetch_retries_max 0
  @request_count_max_default 20
  @request_deadline_ms_default 15_000
  @request_interval_ms_default 1_000
  @request_ms_min 250

  @moduledoc """
  One cycle of route schedule fetches: records the schedules that are due,
  one request after another at a fixed pace, through
  `Gobusgo.OneBusAway.RouteScheduleRecorder`. An item is the schedule of one
  route on one service date.

  The routes are those the route view lists for the agencies of the agency
  view's current fetch, read with `Gobusgo.OneBusAway.RouteItems.route_ids/1`.
  `Gobusgo.OneBusAway.ScheduleDates` says which dates of each are due, from
  the dates the schedule view knows. Routes come in identifier order, each
  route's dates the earliest first. A cycle notes each response it records
  and announces, and each date a route has no service, as an attempt in the
  schedule view, so neither is fetched again.

  A cycle takes at most `:request_count_max` due items and leaves the rest
  to the next cycle. It starts one request every `:request_interval_ms` and
  starts none with less than #{@request_ms_min} ms of `:budget_ms` left.
  Each item is recorded in a task of its own under the given task
  supervisor, so an item whose fetch fails, raises, or stalls is one failed
  item and the cycle goes on to the next. A fetch is not retried within a
  cycle, because the item is still due in the next one.

  ## Results

    * `{:ok, counts}`: at least one item is recorded or has no service, or
      nothing is due. `counts` holds `:due_count`, `:recorded_count`,
      `:no_service_count`, `:failed_count`, `:skipped_count`, the due items
      the budget did not reach, `:deferred_count`, the due items beyond
      `:request_count_max`, `:unannounced_count`, the responses stored whose
      "response stored" event was not published, `:route_count`, and
      `:next_date_ready_count`, the routes whose next date is held or has no
      service once the cycle ends.
    * `{:error, :nothing_recorded}`: items are due, at least one was tried,
      and none is recorded or without service.

  Each call logs once: `debug` `OneBusAway route schedule cycle found
  nothing due`, `info` `OneBusAway route schedule cycle finished` when every
  item tried is recorded and announced or without service, `warning`
  `OneBusAway route schedule cycle finished degraded` when some are, and
  `error` `OneBusAway route schedule cycle failed` when none is, each with
  the counts and `failures`, the count of failed items by cause.

  ## Options

    * `:task_supervisor` (required): the `Task.Supervisor` the items run
      under.
    * `:agency_ids`: a zero-arity function returning the agencies. Defaults
      to the agencies of the current fetch of
      `Gobusgo.OneBusAway.AgencyView`.
    * `:route_view` and `:schedule_view`: the views read. Default to
      `Gobusgo.OneBusAway.RouteView` and
      `Gobusgo.OneBusAway.RouteScheduleView`.
    * `:clock`: returns the current UTC time. Defaults to
      `DateTime.utc_now/0`.
    * `:request_count_max`: defaults to #{@request_count_max_default}.
    * `:request_interval_ms`: defaults to #{@request_interval_ms_default}.
    * `:request_deadline_ms`: the bound on one item. Defaults to
      #{@request_deadline_ms_default}.
    * `:budget_ms`: defaults to #{@budget_ms_default}.
    * `:sleep`: waits the given milliseconds between requests. Defaults to
      `Process.sleep/1`.
    * `:record_options`: options for `RouteScheduleRecorder.record/2`.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.OneBusAway.RouteItems
  alias Gobusgo.OneBusAway.RouteScheduleRecorder
  alias Gobusgo.OneBusAway.RouteScheduleView
  alias Gobusgo.OneBusAway.ScheduleDates

  @type counts :: %{
          due_count: non_neg_integer(),
          recorded_count: non_neg_integer(),
          no_service_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          skipped_count: non_neg_integer(),
          deferred_count: non_neg_integer(),
          unannounced_count: non_neg_integer(),
          route_count: non_neg_integer(),
          next_date_ready_count: non_neg_integer()
        }

  @doc "Records the route schedules that are due, at most one slice of them."
  @spec run(Client.settings(), Keyword.t()) :: {:ok, counts()} | {:error, :nothing_recorded}
  def run(%{api_key: api_key} = settings, options) when is_binary(api_key) and is_list(options) do
    options =
      Keyword.validate!(options, [
        :task_supervisor,
        agency_ids: &current_agency_ids/0,
        route_view: Gobusgo.OneBusAway.RouteView,
        schedule_view: RouteScheduleView,
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

    now = Keyword.fetch!(options, :clock).()

    route_ids =
      RouteItems.route_ids(%{
        agency_ids: Keyword.fetch!(options, :agency_ids).(),
        route_view: Keyword.fetch!(options, :route_view)
      })

    due = due_items(route_ids, now, options)
    {taken, deferred} = Enum.split(due, Keyword.fetch!(options, :request_count_max))
    outcomes = record_each(settings, taken, options)
    Assert.condition(length(outcomes) == length(taken), "every item taken must have an outcome")

    counts =
      outcomes
      |> counts(%{due_count: length(due), deferred_count: length(deferred)})
      |> Map.merge(readiness(route_ids, now, options))

    log(counts, failures(outcomes))

    if counts.failed_count >= 1 and counts.recorded_count + counts.no_service_count == 0 do
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

  defp due_items(route_ids, now, options) do
    known_dates = RouteScheduleView.known_dates(Keyword.fetch!(options, :schedule_view))

    for route_id <- route_ids,
        date <-
          ScheduleDates.due(%{
            route_id: route_id,
            known_dates: Map.get(known_dates, route_id, []),
            now: now
          }) do
      {route_id, date}
    end
  end

  # The routes whose next date is held or has no service, read once the
  # cycle's attempts are noted.
  defp readiness(route_ids, now, options) do
    next_date = now |> DateTime.to_date() |> Date.add(1)
    known_dates = RouteScheduleView.known_dates(Keyword.fetch!(options, :schedule_view))

    ready_count =
      Enum.count(route_ids, fn route_id -> next_date in Map.get(known_dates, route_id, []) end)

    %{route_count: length(route_ids), next_date_ready_count: ready_count}
  end

  defp record_each(settings, items, options) do
    budget_end_ms = System.monotonic_time(:millisecond) + Keyword.fetch!(options, :budget_ms)
    interval_ms = Keyword.fetch!(options, :request_interval_ms)
    request_deadline_ms = Keyword.fetch!(options, :request_deadline_ms)
    sleep = Keyword.fetch!(options, :sleep)

    {outcomes, _next_start_ms} =
      Enum.map_reduce(items, System.monotonic_time(:millisecond), fn item, next_start_ms ->
        wait_ms = next_start_ms - System.monotonic_time(:millisecond)
        if wait_ms > 0, do: sleep.(wait_ms)
        started_ms = System.monotonic_time(:millisecond)
        left_ms = budget_end_ms - started_ms

        outcome =
          if left_ms >= @request_ms_min do
            record(settings, item, min(left_ms, request_deadline_ms), options)
          else
            :skipped
          end

        {outcome, started_ms + interval_ms}
      end)

    outcomes
  end

  defp record(settings, {route_id, service_date}, deadline_ms, options) do
    record_options = Keyword.fetch!(options, :record_options)
    schedule_view = Keyword.fetch!(options, :schedule_view)

    fetch_options =
      Keyword.merge(
        [max_retries: @fetch_retries_max, deadline_ms: deadline_ms],
        Keyword.get(record_options, :fetch_options, [])
      )

    record_options =
      record_options
      |> Keyword.put(:fetch_options, fetch_options)
      |> Keyword.put(:route_id, route_id)
      |> Keyword.put(:service_date, service_date)

    task =
      options
      |> Keyword.fetch!(:task_supervisor)
      |> Task.Supervisor.async_nolink(fn ->
        RouteScheduleRecorder.record(settings, record_options)
      end)

    attempt = %{route_id: route_id, service_date: service_date}

    case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{event_published: true}}} ->
        :ok = RouteScheduleView.note_attempt(schedule_view, attempt)
        :recorded

      {:ok, {:ok, %{event_published: false}}} ->
        :unannounced

      {:ok, {:no_service, _no_service}} ->
        :ok = RouteScheduleView.note_attempt(schedule_view, attempt)
        :no_service

      {:ok, {:error, {stage, reason}}} ->
        {:failed, cause(stage, reason)}

      nil ->
        {:failed, "deadline_exceeded"}

      {:exit, _reason} ->
        {:failed, "crashed"}
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

  defp counts(outcomes, %{due_count: due_count, deferred_count: deferred_count}) do
    recorded_count = Enum.count(outcomes, &(&1 in [:recorded, :unannounced]))
    no_service_count = Enum.count(outcomes, &(&1 == :no_service))
    skipped_count = Enum.count(outcomes, &(&1 == :skipped))

    %{
      due_count: due_count,
      recorded_count: recorded_count,
      no_service_count: no_service_count,
      failed_count: length(outcomes) - recorded_count - no_service_count - skipped_count,
      skipped_count: skipped_count,
      deferred_count: deferred_count,
      unannounced_count: Enum.count(outcomes, &(&1 == :unannounced))
    }
  end

  defp failures(outcomes) do
    for({:failed, cause} <- outcomes, do: cause) |> Enum.frequencies()
  end

  defp log(counts, failures) do
    properties = Map.to_list(counts) ++ [failures: inspect(failures)]
    degraded_count = counts.failed_count + counts.skipped_count + counts.unannounced_count
    succeeded_count = counts.recorded_count + counts.no_service_count

    cond do
      counts.due_count == 0 ->
        Logger.debug("OneBusAway route schedule cycle found nothing due", properties)

      degraded_count == 0 ->
        Logger.info("OneBusAway route schedule cycle finished", properties)

      succeeded_count >= 1 or counts.failed_count == 0 ->
        Logger.warning("OneBusAway route schedule cycle finished degraded", properties)

      true ->
        Logger.error("OneBusAway route schedule cycle failed", properties)
    end
  end
end
