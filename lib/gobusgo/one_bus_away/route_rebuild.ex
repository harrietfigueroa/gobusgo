defmodule Gobusgo.OneBusAway.RouteRebuild do
  @day_count 2
  @page_count_max Gobusgo.OneBusAway.StoredListing.page_count_max()
  @process_count_max 8
  @process_timeout_ms 10_000
  @deadline_ms 60_000

  @moduledoc """
  Fills the route view, the route path view, and the stop view from the
  stored responses, so that a start does not fetch from OneBusAway what it
  already holds.

  `run/1` discovers the stored `routes-for-agency` and `stops-for-route`
  responses of the last #{@day_count} UTC days, keeps the newest of each
  agency and of each route, and hands each to its dataset's processor, which
  publishes it to the views as the processing of a fresh fetch does. A
  record carries the time of its fetch, so an item a rebuild fills is due
  again when its slot next comes, as `Gobusgo.OneBusAway.RouteSchedule`
  decides, and an item the rebuild leaves out is due at once.

  ## Bounds

  Per dataset and day, discovery makes at most #{@page_count_max} calls of
  `Gobusgo.Reader.discovery_limit_max/0` destinations; a day with more
  stored responses is left out and counted. At most #{@process_count_max}
  responses are processed at a time, each with #{@process_timeout_ms} ms.

  `start_link/1` is the form a supervisor runs it in: it runs `run/1` in a
  task under `options[:task_supervisor]`, waits at most
  `options[:deadline_ms]`, #{@deadline_ms} by default, and returns
  `:ignore`, so the children after it start once the rebuild has ended
  whatever its outcome. A rebuild stopped at the deadline keeps what it
  published.

  ## Logs

  One line per run: `Route views rebuilt` at `info` when every discovery
  and every response succeeded, and `Route views rebuilt incomplete` at
  `warning` otherwise, both with the count of responses processed and
  failed per dataset, the count of days whose discovery failed, and the
  time taken. A run that ends otherwise logs `Route views rebuild stopped`
  at `warning` with the `reason`, `:deadline` or `:crashed`.

  ## Options

    * `:now`: a zero-arity function returning the time, by default
      `DateTime.utc_now/0`.
    * `:read_options`: options for `Gobusgo.Reader.read/2` and
      `Gobusgo.Reader.discover/2`.
    * `:publish_options`: options for `Gobusgo.Publisher.publish/2`.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.RawResponse
  alias Gobusgo.OneBusAway.RawRoutePathResponse
  alias Gobusgo.OneBusAway.RawRouteResponse
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RoutePathBatch
  alias Gobusgo.OneBusAway.StoredListing

  @datasets [
    %{name: :routes, prefix: RawRouteResponse.destination_prefix(), processor: RouteBatch},
    %{
      name: :route_paths,
      prefix: RawRoutePathResponse.destination_prefix(),
      processor: RoutePathBatch
    }
  ]

  @typedoc "What a run did for one dataset."
  @type counts :: %{
          processed_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          undiscovered_day_count: non_neg_integer()
        }

  @type result :: %{routes: counts(), route_paths: counts()}

  @doc "The specification of a rebuild as a supervisor's child, run once."
  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(options) when is_list(options) do
    %{id: __MODULE__, start: {__MODULE__, :start_link, [options]}, restart: :temporary}
  end

  @doc """
  Runs `run/1` with the remaining options in a task under
  `options[:task_supervisor]`, waits for it at most `options[:deadline_ms]`,
  and returns `:ignore`.
  """
  @spec start_link(Keyword.t()) :: :ignore
  def start_link(options) when is_list(options) do
    {task_supervisor, options} = Keyword.pop!(options, :task_supervisor)
    {deadline_ms, run_options} = Keyword.pop(options, :deadline_ms, @deadline_ms)
    Assert.condition(is_integer(deadline_ms), "deadline_ms must be an integer")
    Assert.condition(deadline_ms >= 0, "deadline_ms must not be negative, got: #{deadline_ms}")
    task = Task.Supervisor.async_nolink(task_supervisor, fn -> run(run_options) end)

    case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, _result} -> :ok
      nil -> Logger.warning("Route views rebuild stopped", reason: :deadline)
      {:exit, _reason} -> Logger.warning("Route views rebuild stopped", reason: :crashed)
    end

    :ignore
  end

  @doc "Processes the newest stored response of each agency's routes and of each route's paths."
  @spec run(Keyword.t()) :: result()
  def run(options) when is_list(options) do
    options =
      Keyword.validate!(options, now: &DateTime.utc_now/0, read_options: [], publish_options: [])

    now = Keyword.fetch!(options, :now)
    Assert.condition(is_function(now, 0), "now must be a zero-arity function")
    started_ms = System.monotonic_time(:millisecond)
    today = DateTime.to_date(now.())

    context = %{
      dates: for(day_index <- 0..(@day_count - 1)//1, do: Date.add(today, -day_index)),
      read_options: Keyword.fetch!(options, :read_options),
      process_options: Keyword.take(options, [:read_options, :publish_options])
    }

    result = Map.new(@datasets, &{&1.name, rebuild(&1, context)})
    log(result, System.monotonic_time(:millisecond) - started_ms)
    result
  end

  defp rebuild(dataset, context) do
    {newest, undiscovered_day_count} = newest(dataset, context)

    outcomes =
      newest
      |> Task.async_stream(&dataset.processor.process(&1, context.process_options),
        max_concurrency: @process_count_max,
        timeout: @process_timeout_ms,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.map(fn
        {:ok, {:ok, _published}} -> :processed
        {:ok, {:error, _failure}} -> :failed
        {:exit, :timeout} -> :failed
      end)

    processed_count = Enum.count(outcomes, &(&1 == :processed))

    %{
      processed_count: processed_count,
      failed_count: length(outcomes) - processed_count,
      undiscovered_day_count: undiscovered_day_count
    }
  end

  # The newest destination of each item, the dates taken newest first, so an
  # item keeps the destination of the latest day that holds one. Within a
  # day the name of a stored response starts with its fetch time, so the
  # greatest name of an item is its newest.
  defp newest(dataset, %{dates: dates, read_options: read_options}) do
    {by_item, undiscovered_day_count} =
      Enum.reduce(dates, {%{}, 0}, fn date, {by_item, undiscovered_day_count} ->
        prefix = RawResponse.partition_prefix(dataset.prefix, date)

        case StoredListing.list(prefix, read_options) do
          {:ok, destinations} ->
            of_day =
              destinations
              |> Enum.group_by(&item/1)
              |> Map.new(fn {item, of_item} -> {item, Enum.max(of_item)} end)

            {Map.merge(of_day, by_item), undiscovered_day_count}

          :error ->
            {by_item, undiscovered_day_count + 1}
        end
      end)

    {by_item |> Map.values() |> Enum.sort(), undiscovered_day_count}
  end

  # The segments between the date and the name: the item the response is of.
  defp item(destination), do: destination |> Path.dirname() |> Path.basename()

  defp log(result, elapsed_ms) do
    properties = [
      routes_processed_count: result.routes.processed_count,
      routes_failed_count: result.routes.failed_count,
      route_paths_processed_count: result.route_paths.processed_count,
      route_paths_failed_count: result.route_paths.failed_count,
      undiscovered_day_count:
        result.routes.undiscovered_day_count + result.route_paths.undiscovered_day_count,
      elapsed_ms: elapsed_ms
    ]

    if complete?(result.routes) and complete?(result.route_paths) do
      Logger.info("Route views rebuilt", properties)
    else
      Logger.warning("Route views rebuilt incomplete", properties)
    end
  end

  defp complete?(%{failed_count: 0, undiscovered_day_count: 0}), do: true
  defp complete?(_counts), do: false
end
