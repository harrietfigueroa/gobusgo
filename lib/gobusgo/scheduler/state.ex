defmodule Gobusgo.Scheduler.State do
  @moduledoc """
  The cadence rules of one scheduler: whether a tick starts a run, and what a
  finished run changes. Everything here is pure, so the rules are tested with
  no process and no timer.

  A tick starts a run when none is in flight and no backoff is pending. A
  tick during a run is skipped and counted. After a failed run, the ticks of
  a backoff are skipped: 1, 3, 7, then 15 ticks after one to four failures in
  a row, and never more than 15. A successful run clears the failures.
  """

  alias Gobusgo.Assert

  @type outcome :: :ok | :error | :crashed | :deadline_exceeded
  @type finished :: %{outcome: outcome(), finished_at: DateTime.t()}
  @type decision :: :start | :skip
  @type t :: %{
          phase: :idle | :running,
          failure_count: non_neg_integer(),
          backoff_tick_count: non_neg_integer(),
          skipped_tick_count: non_neg_integer(),
          run_skipped_tick_count: non_neg_integer(),
          last_outcome: finished() | nil
        }

  @backoff_tick_count_max 15
  @outcomes [:ok, :error, :crashed, :deadline_exceeded]

  @doc "The most ticks one backoff skips."
  @spec backoff_tick_count_max() :: pos_integer()
  def backoff_tick_count_max, do: @backoff_tick_count_max

  @doc "Returns the state of a scheduler that has run nothing."
  @spec new() :: t()
  def new do
    %{
      phase: :idle,
      failure_count: 0,
      backoff_tick_count: 0,
      skipped_tick_count: 0,
      run_skipped_tick_count: 0,
      last_outcome: nil
    }
  end

  @doc """
  Applies one tick. `:start` means the caller starts a run now, and the state
  holds that run as in flight until `finish/2`. `:skip` means the caller
  starts nothing.
  """
  @spec tick(t()) :: {t(), decision()}
  def tick(%{phase: :running} = state) do
    state = %{
      state
      | skipped_tick_count: state.skipped_tick_count + 1,
        run_skipped_tick_count: state.run_skipped_tick_count + 1
    }

    {state, :skip}
  end

  def tick(%{phase: :idle, backoff_tick_count: backoff_tick_count} = state) do
    if backoff_tick_count >= 1 do
      {%{state | backoff_tick_count: backoff_tick_count - 1}, :skip}
    else
      {%{state | phase: :running, run_skipped_tick_count: 0}, :start}
    end
  end

  @doc """
  Records how the run in flight ended. Every outcome other than `:ok` is a
  failure and starts a backoff.
  """
  @spec finish(t(), finished()) :: t()
  def finish(state, %{outcome: outcome, finished_at: %DateTime{}} = finished) do
    Assert.condition(state.phase == :running, "a run must be in flight, got: #{state.phase}")
    Assert.condition(outcome in @outcomes, "outcome must be known, got: #{inspect(outcome)}")
    state = %{state | phase: :idle, last_outcome: finished}

    case outcome do
      :ok ->
        %{state | failure_count: 0, backoff_tick_count: 0}

      _failure ->
        failure_count = state.failure_count + 1

        %{
          state
          | failure_count: failure_count,
            backoff_tick_count: backoff_tick_count(failure_count)
        }
    end
  end

  # The exponent is bounded before the power is taken, so a long run of
  # failures never computes a large integer.
  defp backoff_tick_count(failure_count) do
    exponent_max = ceil(:math.log2(@backoff_tick_count_max + 1))
    exponent = min(failure_count, exponent_max)
    backoff_tick_count = min(Integer.pow(2, exponent) - 1, @backoff_tick_count_max)
    Assert.condition(backoff_tick_count >= 1, "a failure must back off at least one tick")
    backoff_tick_count
  end
end
