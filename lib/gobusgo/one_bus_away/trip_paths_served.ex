defmodule Gobusgo.OneBusAway.TripPathsServed do
  @interval_ms 3_600_000
  @deadline_ms 5_000
  @requests_at 1
  @trips_at 2
  @counter_key {__MODULE__, :counters}

  @moduledoc """
  The count of `trip-paths:request` requests the node served and of the
  trips they named, logged once an hour as `Trip paths requests served` at
  `info` with `request_count`, `trip_count`, and `interval_ms`.

  The counts live in one `:counters` array held in `:persistent_term`, made
  by `init/0` when the application starts, so recording takes no process and
  no message. `flush/0` reads the counts and sets them to zero, and the
  scheduler of `log_spec/0` calls it every #{@interval_ms} ms. Nothing is
  kept across a restart.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Scheduler

  require Logger

  @typedoc "The counts of one interval."
  @type counts :: %{request_count: non_neg_integer(), trip_count: non_neg_integer()}

  @doc "Makes the counters, all zero. A second call replaces them."
  @spec init() :: :ok
  def init do
    :persistent_term.put(@counter_key, :counters.new(2, [:write_concurrency]))
  end

  @doc """
  Counts one served request that named `trip_count` trips. A count made
  before `init/0` is lost.
  """
  @spec record(non_neg_integer()) :: :ok
  def record(trip_count) when is_integer(trip_count) and trip_count >= 0 do
    case :persistent_term.get(@counter_key, nil) do
      nil ->
        :ok

      counters ->
        :counters.add(counters, @requests_at, 1)
        :counters.add(counters, @trips_at, trip_count)
    end
  end

  @doc "Returns the counts since the last flush and sets them to zero."
  @spec flush() :: counts()
  def flush do
    case :persistent_term.get(@counter_key, nil) do
      nil ->
        %{request_count: 0, trip_count: 0}

      counters ->
        request_count = :counters.get(counters, @requests_at)
        trip_count = :counters.get(counters, @trips_at)
        :counters.sub(counters, @requests_at, request_count)
        :counters.sub(counters, @trips_at, trip_count)
        %{request_count: request_count, trip_count: trip_count}
    end
  end

  @doc "Flushes the counts and logs them. This is the run of the hourly scheduler."
  @spec log() :: {:ok, counts()}
  def log do
    counts = flush()

    Logger.info(
      "Trip paths requests served",
      request_count: counts.request_count,
      trip_count: counts.trip_count,
      interval_ms: @interval_ms
    )

    {:ok, counts}
  end

  @doc "The spec of the scheduler that logs the counts every hour."
  @spec log_spec() :: Scheduler.spec()
  def log_spec do
    spec = %{
      name: Gobusgo.TripPathsServedScheduler,
      run: &log/0,
      cadence: %{policy: {:fixed, @interval_ms}, signals: &no_signals/0},
      deadline_ms: @deadline_ms
    }

    Scheduler.assert_spec(spec)
    Assert.condition(spec.deadline_ms < @interval_ms, "the run ends before the next is due")
    spec
  end

  defp no_signals, do: %{}
end
