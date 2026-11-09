defmodule Gobusgo.OneBusAway.RouteScheduleRebuild do
  @day_count 3
  @read_count_max 8
  @process_timeout_ms 15_000
  @deadline_ms 60_000

  @moduledoc """
  Fills the route schedule view from the stored responses, so that a start
  does not fetch from OneBusAway the schedules it already holds.

  `run/1` discovers the stored `schedule-for-route` responses of the last
  #{@day_count} UTC fetch dates, keeps those of the service dates
  `Gobusgo.OneBusAway.ScheduleDates` wants today, the day before the UTC
  date to the day after it, keeps the newest of each route and service
  date, and hands each to `Gobusgo.OneBusAway.RouteScheduleBatch`, which
  publishes it to the view as the processing of a fresh fetch does. A
  service date the rebuild fills is never fetched again, and one it leaves
  out is due at once.

  ## Bounds

  Per fetch date, discovery makes at most
  `Gobusgo.OneBusAway.StoredListing.page_count_max/0` calls; a day with more
  stored responses is left out and counted. At most #{@read_count_max}
  responses are read at a time, and at most `:process_count_max` processed,
  by default as many as the node has schedulers online and never more than
  #{@read_count_max}: a decoded response is held whole while it is
  processed, and processing more at once than runs in parallel holds more
  responses for no gain in time. A read and a processing each have
  #{@process_timeout_ms} ms.

  `start_link/1` is the form a supervisor runs it in: it runs `run/1` in a
  task under `options[:task_supervisor]`, waits at most
  `options[:deadline_ms]`, #{@deadline_ms} by default, and returns
  `:ignore`, so the children after it start once the rebuild has ended
  whatever its outcome. A rebuild stopped at the deadline keeps what it
  published.

  ## Logs

  One line per run: `Route schedule view rebuilt` at `info` when every
  discovery and every response succeeded, and `Route schedule view rebuilt
  incomplete` at `warning` otherwise, both with the count of responses
  processed and failed, the count of days whose discovery failed, and the
  time taken. A run that ends otherwise logs `Route schedule view rebuild
  stopped` at `warning` with the `reason`, `:deadline` or `:crashed`.

  ## Options

    * `:now`: a zero-arity function returning the time, by default
      `DateTime.utc_now/0`.
    * `:read_options`: options for `Gobusgo.Reader.read/2` and
      `Gobusgo.Reader.discover/2`.
    * `:publish_options`: options for `Gobusgo.Publisher.publish/2`.
    * `:process_count_max`: how many responses are processed at once.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.RawResponse
  alias Gobusgo.OneBusAway.RawRouteScheduleResponse
  alias Gobusgo.OneBusAway.RouteScheduleBatch
  alias Gobusgo.OneBusAway.StoredListing

  @type result :: %{
          processed_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          undiscovered_day_count: non_neg_integer()
        }

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
      nil -> Logger.warning("Route schedule view rebuild stopped", reason: :deadline)
      {:exit, _reason} -> Logger.warning("Route schedule view rebuild stopped", reason: :crashed)
    end

    :ignore
  end

  @doc "Processes the newest stored schedule of each route on each service date wanted today."
  @spec run(Keyword.t()) :: result()
  def run(options) when is_list(options) do
    options =
      Keyword.validate!(options,
        now: &DateTime.utc_now/0,
        read_options: [],
        publish_options: [],
        process_count_max: min(System.schedulers_online(), @read_count_max)
      )

    now = Keyword.fetch!(options, :now)
    Assert.condition(is_function(now, 0), "now must be a zero-arity function")
    started_ms = System.monotonic_time(:millisecond)
    today = DateTime.to_date(now.())
    wanted = MapSet.new([Date.add(today, -1), today, Date.add(today, 1)])
    fetch_dates = for day_index <- 0..(@day_count - 1)//1, do: Date.add(today, -day_index)
    read_options = Keyword.fetch!(options, :read_options)
    process_options = Keyword.take(options, [:read_options, :publish_options])

    {newest, undiscovered_day_count} = newest(fetch_dates, wanted, read_options)

    process_count_max = Keyword.fetch!(options, :process_count_max)
    Assert.condition(is_integer(process_count_max), "process_count_max must be an integer")
    Assert.condition(process_count_max > 0, "process_count_max must be positive")

    # The reads wait on the store and hold only the content, so more run at
    # once than there are schedulers; a response decoded is held whole while
    # it is processed, so no more are processed at once than run in parallel.
    outcomes =
      newest
      |> Task.async_stream(&{&1, RouteScheduleBatch.read_stored(&1, process_options)},
        max_concurrency: @read_count_max,
        timeout: @process_timeout_ms,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Task.async_stream(&process_read(&1, process_options),
        max_concurrency: process_count_max,
        timeout: @process_timeout_ms,
        on_timeout: :kill_task,
        ordered: false
      )
      |> Enum.map(fn
        {:ok, {:ok, _published}} -> :processed
        {:ok, {:error, _failure}} -> :failed
        {:ok, :read_timeout} -> :failed
        {:exit, :timeout} -> :failed
      end)

    processed_count = Enum.count(outcomes, &(&1 == :processed))

    result = %{
      processed_count: processed_count,
      failed_count: length(outcomes) - processed_count,
      undiscovered_day_count: undiscovered_day_count
    }

    log(result, System.monotonic_time(:millisecond) - started_ms)
    result
  end

  defp process_read({:ok, {destination, {:ok, content}}}, process_options) do
    RouteScheduleBatch.process_content(
      %{destination: destination, content: content},
      process_options
    )
  end

  defp process_read({:ok, {_destination, {:error, failure}}}, _process_options),
    do: {:error, failure}

  defp process_read({:exit, :timeout}, _process_options), do: :read_timeout

  # The newest destination of each route and service date, the fetch dates
  # taken newest first, so an item keeps the destination of the latest day
  # that holds one. Within a day the name of a stored response starts with
  # its fetch time, so the greatest name of an item is its newest.
  defp newest(fetch_dates, wanted, read_options) do
    {by_item, undiscovered_day_count} =
      Enum.reduce(fetch_dates, {%{}, 0}, fn date, {by_item, undiscovered_day_count} ->
        prefix = RawResponse.partition_prefix(RawRouteScheduleResponse.destination_prefix(), date)

        case StoredListing.list(prefix, read_options) do
          {:ok, destinations} ->
            of_day =
              destinations
              |> Enum.filter(&wanted?(&1, wanted))
              |> Enum.group_by(&Path.dirname/1)
              |> Map.new(fn {directory, of_item} -> {item(directory), Enum.max(of_item)} end)

            {Map.merge(of_day, by_item), undiscovered_day_count}

          :error ->
            {by_item, undiscovered_day_count + 1}
        end
      end)

    {by_item |> Map.values() |> Enum.sort(), undiscovered_day_count}
  end

  # The route and service date segments: the item the response is of.
  defp item(directory) do
    {Path.basename(Path.dirname(directory)), Path.basename(directory)}
  end

  defp wanted?(destination, wanted) do
    case RawRouteScheduleResponse.service_date(destination) do
      {:ok, service_date} -> MapSet.member?(wanted, service_date)
      :error -> false
    end
  end

  defp log(result, elapsed_ms) do
    properties = Map.to_list(result) ++ [elapsed_ms: elapsed_ms]

    if result.failed_count == 0 and result.undiscovered_day_count == 0 do
      Logger.info("Route schedule view rebuilt", properties)
    else
      Logger.warning("Route schedule view rebuilt incomplete", properties)
    end
  end
end
