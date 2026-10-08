defmodule Gobusgo.OneBusAway.RouteCycle do
  @agency_count_max 64
  @budget_ms_default 50_000
  @fetch_retries_max 0
  @request_count_max_default 45
  @request_deadline_ms_default 10_000
  @request_interval_ms_default 1_000
  @request_ms_min 250
  @route_count_max 5_000

  @moduledoc """
  One cycle of route fetches: records the route data that is due, one
  request after another at a fixed pace. An item is the routes of one agency,
  recorded through `Gobusgo.OneBusAway.RouteRecorder`, or the stops and paths
  of one route, recorded through `Gobusgo.OneBusAway.RoutePathRecorder`.

  The agencies are those of the agency view's current fetch, and the routes
  are those the route view holds for them. `Gobusgo.OneBusAway.RouteSchedule`
  says which are due, from the attempt time each has in its view: an item
  with no fetch, and an item whose slot has come since its last fetch.
  Agencies come before routes, each in identifier order. A cycle notes each
  response it records and announces as an attempt in the item's view, so an
  item whose response does not process waits for its slot like any other.

  A cycle takes at most `:request_count_max` due items and leaves the rest
  to the next cycle. It starts one request every `:request_interval_ms` and
  starts none with less than #{@request_ms_min} ms of `:budget_ms` left, the
  least time in which a request is still worth starting. Each item is recorded in a task of
  its own under the given task supervisor, so an item whose fetch fails,
  raises, or stalls is one failed item and the cycle goes on to the next. A
  fetch is not retried within a cycle, because the item is still due in the
  next one. A cycle reads at most #{@agency_count_max} agencies and
  #{@route_count_max} routes.

  ## Results

    * `{:ok, counts}`: at least one item is recorded, or nothing is due.
      `counts` holds `:due_count`, `:recorded_count`, `:failed_count`,
      `:skipped_count`, the due items the budget did not reach,
      `:deferred_count`, the due items beyond `:request_count_max`, and
      `:unannounced_count`, the responses stored whose "response stored"
      event was not published.
    * `{:error, :nothing_recorded}`: items are due, at least one was tried,
      and none is recorded.

  Each call logs once: `debug` `OneBusAway route cycle found nothing due`,
  `info` `OneBusAway route cycle finished` when every item tried is
  recorded and announced, `warning`
  `OneBusAway route cycle finished degraded` when some are, and `error`
  `OneBusAway route cycle failed` when none is, each with the counts and
  `failures`, the count of failed items by cause.

  ## Options

    * `:task_supervisor` (required): the `Task.Supervisor` the items run
      under.
    * `:agency_ids`: a zero-arity function returning the agencies. Defaults
      to the agencies of the current fetch of
      `Gobusgo.OneBusAway.AgencyView`.
    * `:route_view` and `:route_path_view`: the fetch views read. Default to
      `Gobusgo.OneBusAway.RouteView` and `Gobusgo.OneBusAway.RoutePathView`.
    * `:clock`: returns the current UTC time. Defaults to
      `DateTime.utc_now/0`.
    * `:request_count_max`: defaults to #{@request_count_max_default}.
    * `:request_interval_ms`: defaults to #{@request_interval_ms_default}.
    * `:request_deadline_ms`: the bound on one item. Defaults to
      #{@request_deadline_ms_default}.
    * `:budget_ms`: defaults to #{@budget_ms_default}.
    * `:sleep`: waits the given milliseconds between requests. Defaults to
      `Process.sleep/1`.
    * `:record_options`: options for both recorders' `record/2`.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RoutePathRecorder
  alias Gobusgo.OneBusAway.RouteRecorder
  alias Gobusgo.OneBusAway.RouteSchedule

  @type counts :: %{
          due_count: non_neg_integer(),
          recorded_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          skipped_count: non_neg_integer(),
          deferred_count: non_neg_integer(),
          unannounced_count: non_neg_integer()
        }

  @typedoc "One fetch a cycle can make: an agency's routes, or a route's stops and paths."
  @type item :: {:routes, String.t()} | {:route_path, String.t()}

  @doc "Records the route data that is due, at most one slice of it."
  @spec run(Client.settings(), Keyword.t()) :: {:ok, counts()} | {:error, :nothing_recorded}
  def run(%{api_key: api_key} = settings, options) when is_binary(api_key) and is_list(options) do
    options =
      Keyword.validate!(options, [
        :task_supervisor,
        agency_ids: &current_agency_ids/0,
        route_view: Gobusgo.OneBusAway.RouteView,
        route_path_view: Gobusgo.OneBusAway.RoutePathView,
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

    due = due_items(options)
    {taken, deferred} = Enum.split(due, Keyword.fetch!(options, :request_count_max))
    outcomes = record_each(settings, taken, options)
    Assert.condition(length(outcomes) == length(taken), "every item taken must have an outcome")

    counts = counts(outcomes, %{due_count: length(due), deferred_count: length(deferred)})
    log(counts, failures(outcomes))

    if counts.failed_count >= 1 and counts.recorded_count == 0 do
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

  # The due agencies, then the due routes of the agencies' current fetches.
  defp due_items(options) do
    now = Keyword.fetch!(options, :clock).()
    route_view = Keyword.fetch!(options, :route_view)
    agency_ids = options |> Keyword.fetch!(:agency_ids) |> then(& &1.()) |> Enum.sort()
    agency_count = length(agency_ids)

    Assert.condition(
      agency_count <= @agency_count_max,
      "a cycle reads at most #{@agency_count_max} agencies, got: #{agency_count}"
    )

    route_ids =
      agency_ids
      |> Enum.flat_map(fn agency_id ->
        case FetchView.current_fetch(route_view, agency_id) do
          nil -> []
          %{route_ids: route_ids} -> route_ids
        end
      end)
      |> Enum.uniq()
      |> Enum.sort()

    route_count = length(route_ids)

    Assert.condition(
      route_count <= @route_count_max,
      "a cycle reads at most #{@route_count_max} routes, got: #{route_count}"
    )

    route_path_view = Keyword.fetch!(options, :route_path_view)

    due(:routes, agency_ids, FetchView.attempt_times(route_view), now) ++
      due(:route_path, route_ids, FetchView.attempt_times(route_path_view), now)
  end

  defp due(kind, ids, attempt_times, now) do
    for id <- ids,
        RouteSchedule.due?(%{id: id, fetched_at: Map.get(attempt_times, id), now: now}) do
      {kind, id}
    end
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

  defp record(settings, {kind, id}, deadline_ms, options) do
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
      |> Task.Supervisor.async_nolink(fn -> record_item(settings, kind, id, record_options) end)

    case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ok, %{event_published: true, fetched_at: fetched_at}}} ->
        :ok = FetchView.note_attempt(view(kind, options), %{id: id, fetched_at: fetched_at})
        :recorded

      {:ok, {:ok, %{event_published: false}}} ->
        :unannounced

      {:ok, {:error, {stage, reason}}} ->
        {:failed, cause(stage, reason)}

      nil ->
        {:failed, "deadline_exceeded"}

      {:exit, _reason} ->
        {:failed, "crashed"}
    end
  end

  defp view(:routes, options), do: Keyword.fetch!(options, :route_view)
  defp view(:route_path, options), do: Keyword.fetch!(options, :route_path_view)

  defp record_item(settings, :routes, agency_id, record_options) do
    RouteRecorder.record(settings, Keyword.put(record_options, :agency_id, agency_id))
  end

  defp record_item(settings, :route_path, route_id, record_options) do
    RoutePathRecorder.record(settings, Keyword.put(record_options, :route_id, route_id))
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
    skipped_count = Enum.count(outcomes, &(&1 == :skipped))

    %{
      due_count: due_count,
      recorded_count: recorded_count,
      failed_count: length(outcomes) - recorded_count - skipped_count,
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

    cond do
      counts.due_count == 0 ->
        Logger.debug("OneBusAway route cycle found nothing due", properties)

      degraded_count == 0 ->
        Logger.info("OneBusAway route cycle finished", properties)

      counts.recorded_count >= 1 or counts.failed_count == 0 ->
        Logger.warning("OneBusAway route cycle finished degraded", properties)

      true ->
        Logger.error("OneBusAway route cycle failed", properties)
    end
  end
end
