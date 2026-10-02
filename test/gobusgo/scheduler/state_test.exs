defmodule Gobusgo.Scheduler.StateTest do
  # Drives the pure cadence rules with sequences of ticks and finished runs,
  # and reads the decision each tick returns and the status the state holds.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Scheduler.State

  @finished_at ~U[2026-10-02 03:15:00Z]

  defp finish(state, outcome) do
    State.finish(state, %{outcome: outcome, finished_at: @finished_at})
  end

  # Applies `count` ticks and returns the state with the decisions in order.
  defp tick_times(state, count) do
    Enum.reduce(1..count//1, {state, []}, fn _index, {state, decisions} ->
      {state, decision} = State.tick(state)
      {state, decisions ++ [decision]}
    end)
  end

  # Fails `count` runs in a row, ticking through each backoff in between, and
  # returns the state as the last failed run leaves it.
  defp fail_times(state, count) do
    Enum.reduce(1..count//1, state, fn _index, state ->
      state = tick_until_start(state)
      finish(state, :error)
    end)
  end

  defp tick_until_start(state) do
    Enum.reduce_while(1..(State.backoff_tick_count_max() + 1)//1, state, fn _index, state ->
      case State.tick(state) do
        {state, :start} -> {:halt, state}
        {state, :skip} -> {:cont, state}
      end
    end)
  end

  describe "new/0" do
    test "starts idle with nothing counted and no outcome" do
      assert State.new() == %{
               phase: :idle,
               failure_count: 0,
               backoff_tick_count: 0,
               skipped_tick_count: 0,
               run_skipped_tick_count: 0,
               last_outcome: nil
             }
    end
  end

  describe "tick/1" do
    test "starts a run when idle" do
      assert {%{phase: :running}, :start} = State.tick(State.new())
    end

    test "skips and counts a tick that arrives during a run" do
      {state, :start} = State.tick(State.new())

      assert {state, [:skip, :skip]} = tick_times(state, 2)
      assert state.phase == :running
      assert state.skipped_tick_count == 2
      assert state.run_skipped_tick_count == 2
    end

    test "starts the next run on the first tick after a successful one" do
      {state, :start} = State.tick(State.new())
      state = finish(state, :ok)

      assert {%{phase: :running}, :start} = State.tick(state)
    end

    test "counts the skipped ticks of each run apart and of all runs together" do
      {state, :start} = State.tick(State.new())
      {state, [:skip]} = tick_times(state, 1)
      state = finish(state, :ok)
      {state, :start} = State.tick(state)

      assert state.run_skipped_tick_count == 0
      assert state.skipped_tick_count == 1
    end
  end

  describe "finish/2" do
    for outcome <- [:ok, :error, :crashed, :deadline_exceeded] do
      test "records the #{outcome} outcome and returns to idle" do
        {state, :start} = State.tick(State.new())
        state = finish(state, unquote(outcome))

        assert state.phase == :idle
        assert state.last_outcome == %{outcome: unquote(outcome), finished_at: @finished_at}
      end
    end

    test "refuses an outcome while no run is in flight" do
      assert_raise AssertionError, fn -> finish(State.new(), :ok) end
    end

    test "refuses an outcome it does not know" do
      {state, :start} = State.tick(State.new())

      assert_raise AssertionError, fn -> finish(state, :unknown) end
    end
  end

  describe "backoff" do
    for {outcome, index} <- Enum.with_index([:error, :crashed, :deadline_exceeded]) do
      test "a run that ends #{outcome} counts as a failure (case #{index})" do
        {state, :start} = State.tick(State.new())
        state = finish(state, unquote(outcome))

        assert state.failure_count == 1
        assert state.backoff_tick_count == 1
      end
    end

    for {failure_count, skip_count} <- [{1, 1}, {2, 3}, {3, 7}, {4, 15}] do
      test "#{failure_count} failures in a row skip #{skip_count} ticks before the next run" do
        state = fail_times(State.new(), unquote(failure_count))

        {state, decisions} = tick_times(state, unquote(skip_count))
        assert decisions == List.duplicate(:skip, unquote(skip_count))
        assert {_state, :start} = State.tick(state)
      end
    end

    test "never skips more ticks than the maximum" do
      state = fail_times(State.new(), 12)

      assert state.failure_count == 12
      assert state.backoff_tick_count == State.backoff_tick_count_max()
    end

    test "does not count a tick skipped for backoff as a tick skipped during a run" do
      state = fail_times(State.new(), 1)
      {state, [:skip]} = tick_times(state, 1)

      assert state.skipped_tick_count == 0
    end

    test "a successful run clears the failures" do
      state = fail_times(State.new(), 2)
      state = tick_until_start(state)
      state = finish(state, :ok)

      assert state.failure_count == 0
      assert state.backoff_tick_count == 0
      assert {_state, :start} = State.tick(state)
    end
  end
end
