defmodule Gobusgo.Scheduler.State do
  @moduledoc """
  The cadence rules of one scheduler: whether a tick starts a run, and what a
  finished run changes. Everything here is pure: the caller reads the clock
  and passes the time in, so the rules are tested with no process and no
  timer.

  Every call takes the current time and the source's interval. The time is
  in milliseconds on a clock that never goes back, and the interval may
  differ from one call to the next.

  A tick starts a run when none is in flight, the interval it is given has
  elapsed since the last run started, and no backoff is pending. The first
  tick starts a run. An interval that shortens while the source waits
  therefore takes effect on the next tick.

  A tick during a run is skipped. Each interval that elapses during a run is
  counted as skipped, for the run and for all runs together.

  A failed run starts a backoff, which delays the next run by 1, 3, 7, then
  15 intervals after one to four failures in a row, and never by more than
  15. The backoff is a duration, sized by the interval `finish/3` is given.
  It counts from the time the next run was due: one interval after the
  failed run started, or the time the run finished when that is later. A
  pending backoff keeps its end when the interval changes. A successful run
  clears the failures.
  """

  alias Gobusgo.Assert

  @type outcome :: :ok | :error | :crashed | :deadline_exceeded
  @type finished :: %{outcome: outcome(), finished_at: DateTime.t()}
  @type time :: %{now_ms: integer(), interval_ms: pos_integer()}
  @type decision :: :start | :skip
  @type t :: %{
          phase: :idle | :running,
          failure_count: non_neg_integer(),
          run_start_ms: integer() | nil,
          backoff_end_ms: integer() | nil,
          skipped_interval_count: non_neg_integer(),
          run_skipped_interval_count: non_neg_integer(),
          last_outcome: finished() | nil
        }

  @backoff_interval_count_max 15
  @outcomes [:ok, :error, :crashed, :deadline_exceeded]

  @doc "The most intervals one backoff delays the next run by."
  @spec backoff_interval_count_max() :: pos_integer()
  def backoff_interval_count_max, do: @backoff_interval_count_max

  @doc """
  Returns the state of a scheduler that has run nothing. `run_start_ms` is
  the time the last run started at, and `backoff_end_ms` the time a pending
  backoff ends at; each is `nil` when there is none.
  """
  @spec new() :: t()
  def new do
    %{
      phase: :idle,
      failure_count: 0,
      run_start_ms: nil,
      backoff_end_ms: nil,
      skipped_interval_count: 0,
      run_skipped_interval_count: 0,
      last_outcome: nil
    }
  end

  @doc """
  Applies one tick at `time`. `:start` means the caller starts a run now, and
  the state holds that run as in flight until `finish/3`. `:skip` means the
  caller starts nothing. `time.now_ms` must not be earlier than the start of
  the last run.
  """
  @spec tick(t(), time()) :: {t(), decision()}
  def tick(%{phase: :running} = state, time) do
    assert_time(state, time)
    {count_skipped_intervals(state, time), :skip}
  end

  def tick(%{phase: :idle} = state, %{now_ms: now_ms} = time) do
    assert_time(state, time)

    if due?(state, time) do
      state = %{
        state
        | phase: :running,
          run_start_ms: now_ms,
          backoff_end_ms: nil,
          run_skipped_interval_count: 0
      }

      {state, :start}
    else
      {state, :skip}
    end
  end

  @doc """
  Records how the run in flight ended at `time`. Every outcome other than
  `:ok` is a failure and starts a backoff sized by `time.interval_ms`.
  `time.now_ms` must not be earlier than the start of the run.
  """
  @spec finish(t(), finished(), time()) :: t()
  def finish(state, %{outcome: outcome, finished_at: %DateTime{}} = finished, time) do
    Assert.condition(state.phase == :running, "a run must be in flight, got: #{state.phase}")
    Assert.condition(outcome in @outcomes, "outcome must be known, got: #{inspect(outcome)}")
    assert_time(state, time)
    state = count_skipped_intervals(state, time)
    state = %{state | phase: :idle, last_outcome: finished}

    case outcome do
      :ok ->
        %{state | failure_count: 0, backoff_end_ms: nil}

      _failure ->
        failure_count = state.failure_count + 1
        next_run_due_ms = max(state.run_start_ms + time.interval_ms, time.now_ms)
        backoff_ms = backoff_interval_count(failure_count) * time.interval_ms
        %{state | failure_count: failure_count, backoff_end_ms: next_run_due_ms + backoff_ms}
    end
  end

  defp due?(%{run_start_ms: nil}, _time), do: true

  defp due?(%{run_start_ms: run_start_ms, backoff_end_ms: backoff_end_ms}, time) do
    interval_elapsed? = time.now_ms - run_start_ms >= time.interval_ms
    backoff_over? = backoff_end_ms == nil or time.now_ms >= backoff_end_ms
    interval_elapsed? and backoff_over?
  end

  defp count_skipped_intervals(state, %{now_ms: now_ms, interval_ms: interval_ms}) do
    elapsed_interval_count = Integer.floor_div(now_ms - state.run_start_ms, interval_ms)

    # An interval that lengthens during a run makes fewer intervals fit in
    # the same elapsed time, and a skipped interval stays counted.
    run_skipped_interval_count = max(state.run_skipped_interval_count, elapsed_interval_count)
    added_interval_count = run_skipped_interval_count - state.run_skipped_interval_count

    %{
      state
      | run_skipped_interval_count: run_skipped_interval_count,
        skipped_interval_count: state.skipped_interval_count + added_interval_count
    }
  end

  # The exponent is bounded before the power is taken, so a long run of
  # failures never computes a large integer.
  defp backoff_interval_count(failure_count) do
    exponent_max = ceil(:math.log2(@backoff_interval_count_max + 1))
    exponent = min(failure_count, exponent_max)
    interval_count = min(Integer.pow(2, exponent) - 1, @backoff_interval_count_max)
    Assert.condition(interval_count >= 1, "a failure must back off at least one interval")
    interval_count
  end

  defp assert_time(state, %{now_ms: now_ms, interval_ms: interval_ms}) do
    Assert.condition(is_integer(now_ms), "now_ms must be an integer, got: #{inspect(now_ms)}")
    Assert.condition(is_integer(interval_ms), "interval_ms must be an integer")
    Assert.condition(interval_ms >= 1, "interval_ms must be positive, got: #{interval_ms}")

    case state.run_start_ms do
      nil ->
        :ok

      run_start_ms ->
        Assert.condition(
          now_ms >= run_start_ms,
          "time must not go back, got: #{now_ms} after #{run_start_ms}"
        )
    end
  end
end
