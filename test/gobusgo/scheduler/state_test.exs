defmodule Gobusgo.Scheduler.StateTest do
  # Drives the pure cadence rules with ticks and finished runs at times the
  # test names, with no process and no timer, and reads the decision each
  # tick returns and the status the state holds. A simulated scheduler ticks
  # once per evaluation period from a time of zero.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.Sources
  alias Gobusgo.Scheduler
  alias Gobusgo.Scheduler.State

  @finished_at ~U[2026-10-02 03:15:00Z]
  @interval_ms 60_000
  @run_duration_ms 200
  @period_ms Scheduler.evaluation_period_ms()

  defp time(now_ms, interval_ms \\ @interval_ms) do
    %{now_ms: now_ms, interval_ms: interval_ms}
  end

  defp finish(state, outcome, time) do
    State.finish(state, %{outcome: outcome, finished_at: @finished_at}, time)
  end

  defp start_at(now_ms, interval_ms \\ @interval_ms) do
    {state, :start} = State.tick(State.new(), time(now_ms, interval_ms))
    state
  end

  # Ticks once per evaluation period from `from_ms` until a tick starts a
  # run, and returns the state with the time of that tick.
  defp tick_until_start(state, from_ms, interval_ms) do
    tick_count_max = Integer.floor_div(interval_ms, @period_ms) * 20

    Enum.reduce_while(0..tick_count_max//1, state, fn tick_index, state ->
      now_ms = from_ms + tick_index * @period_ms

      case State.tick(state, time(now_ms, interval_ms)) do
        {state, :start} -> {:halt, {state, now_ms}}
        {state, :skip} -> {:cont, state}
      end
    end)
  end

  # Runs `count` runs one after another from a time of zero, each ending with
  # `outcome` a moment after it starts, and returns the state after the last
  # with the times the runs started at.
  defp run_times(count, outcome, interval_ms) do
    {state, _from_ms, start_times_ms} =
      Enum.reduce(1..count//1, {State.new(), 0, []}, fn _index, {state, from_ms, starts} ->
        {state, start_ms} = tick_until_start(state, from_ms, interval_ms)
        state = finish(state, outcome, time(start_ms + @run_duration_ms, interval_ms))
        {state, start_ms + @period_ms, starts ++ [start_ms]}
      end)

    {state, start_times_ms}
  end

  describe "new/0" do
    test "starts idle with nothing counted, no run, no backoff, and no outcome" do
      assert State.new() == %{
               phase: :idle,
               failure_count: 0,
               run_start_ms: nil,
               backoff_end_ms: nil,
               skipped_interval_count: 0,
               run_skipped_interval_count: 0,
               last_outcome: nil
             }
    end
  end

  describe "tick/2" do
    test "starts the first run at whatever time it is given" do
      assert {%{phase: :running, run_start_ms: -5_000}, :start} =
               State.tick(State.new(), time(-5_000))
    end

    test "skips a tick that arrives during a run" do
      state = start_at(0)

      assert {%{phase: :running, run_start_ms: 0}, :skip} = State.tick(state, time(@period_ms))
    end

    test "skips a tick before the interval has elapsed since the last run started" do
      state = finish(start_at(0), :ok, time(@run_duration_ms))

      assert {%{phase: :idle}, :skip} = State.tick(state, time(@interval_ms - 1))
    end

    test "starts a run once the interval has elapsed since the last run started" do
      state = finish(start_at(0), :ok, time(@run_duration_ms))

      assert {%{phase: :running, run_start_ms: @interval_ms}, :start} =
               State.tick(state, time(@interval_ms))
    end

    test "starts a run at once after a run that took longer than the interval" do
      state = finish(start_at(0), :ok, time(@interval_ms + 300))

      assert {%{phase: :running}, :start} = State.tick(state, time(@interval_ms + 301))
    end

    # Each offset moves the interval's end to another place between two
    # ticks; the run has to start on the first tick at or after it.
    for offset_ms <- [0, 1, 499, 999] do
      test "starts a run within one evaluation period of the interval elapsing (offset #{offset_ms})" do
        interval_ms = @interval_ms + unquote(offset_ms)
        state = finish(start_at(0, interval_ms), :ok, time(@run_duration_ms, interval_ms))

        {_state, start_ms} = tick_until_start(state, @period_ms, interval_ms)

        assert start_ms >= interval_ms
        assert start_ms - interval_ms < @period_ms
      end
    end

    test "starts a run within one evaluation period of an interval that shortens during the wait" do
      state = finish(start_at(0), :ok, time(@run_duration_ms))
      {state, :skip} = State.tick(state, time(10_000, @interval_ms))

      assert {%{phase: :running}, :start} = State.tick(state, time(10_000 + @period_ms, 5_000))
    end

    test "waits longer under an interval that lengthens during the wait" do
      state = finish(start_at(0), :ok, time(@run_duration_ms))

      assert {%{phase: :idle}, :skip} = State.tick(state, time(@interval_ms, @interval_ms * 2))
    end

    for {field, value} <- [now_ms: 1.5, now_ms: nil, interval_ms: 0, interval_ms: 1.5] do
      test "refuses a time whose #{field} is #{inspect(value)}" do
        time = Map.put(time(0), unquote(field), unquote(value))

        assert_raise AssertionError, fn -> State.tick(State.new(), time) end
      end
    end

    test "refuses a time before the last run started" do
      state = start_at(1_000)

      assert_raise AssertionError, fn -> State.tick(state, time(999)) end
    end
  end

  describe "cadence" do
    # Simulates each source's scheduler over ten runs that succeed, with the
    # interval read from the source's spec, and compares the times the runs
    # start at with multiples of the interval listed for the source.
    for {name, interval_ms} <- [
          {Gobusgo.OneBusAway.AgencyScheduler, 60_000},
          {Gobusgo.OneBusAway.VehicleScheduler, 5_000},
          {Gobusgo.OneBusAway.RouteScheduler, 60_000},
          {Gobusgo.OneBusAway.ArrivalScheduler, 5_000}
        ] do
      test "#{inspect(name)} starts a run every #{interval_ms} ms" do
        specs =
          Sources.specs(%{base_url: "https://oba.example.test", api_key: "test-key"},
            vehicle_cycle_options: [],
            route_cycle_options: [],
            arrival_cycle_options: []
          )

        spec = Enum.find(specs, &(&1.name == unquote(name)))

        {_state, start_times_ms} = run_times(10, :ok, spec.interval_ms)

        assert start_times_ms == Enum.map(0..9, &(&1 * unquote(interval_ms)))
      end
    end
  end

  describe "skipped intervals" do
    for {run_duration_ms, count} <- [
          {@interval_ms - 1, 0},
          {@interval_ms, 1},
          {@interval_ms * 2 + 500, 2}
        ] do
      test "a run of #{run_duration_ms} ms skips #{count} intervals" do
        state = finish(start_at(0), :ok, time(unquote(run_duration_ms)))

        assert state.run_skipped_interval_count == unquote(count)
        assert state.skipped_interval_count == unquote(count)
      end
    end

    test "are counted by a tick while the run is in flight" do
      state = start_at(0)

      {state, :skip} = State.tick(state, time(@interval_ms * 2))

      assert state.phase == :running
      assert state.run_skipped_interval_count == 2
    end

    test "are counted once when several ticks arrive inside one interval" do
      state = start_at(0)
      {state, :skip} = State.tick(state, time(@interval_ms))
      {state, :skip} = State.tick(state, time(@interval_ms + @period_ms))

      assert finish(state, :ok, time(@interval_ms + @period_ms * 2)).skipped_interval_count == 1
    end

    test "are counted for each run apart and for all runs together" do
      state = finish(start_at(0), :ok, time(@interval_ms))
      {state, :start} = State.tick(state, time(@interval_ms))

      assert state.run_skipped_interval_count == 0
      assert state.skipped_interval_count == 1
    end

    test "never fall when the interval lengthens during a run" do
      state = start_at(0)
      {state, :skip} = State.tick(state, time(@interval_ms * 2))

      state = finish(state, :ok, time(@interval_ms * 2 + 1, @interval_ms * 10))

      assert state.run_skipped_interval_count == 2
    end

    test "do not include an interval that passes during a backoff" do
      state = finish(start_at(0), :error, time(@run_duration_ms))
      {state, :skip} = State.tick(state, time(@interval_ms))

      assert state.skipped_interval_count == 0
    end
  end

  describe "finish/3" do
    for outcome <- [:ok, :error, :crashed, :deadline_exceeded] do
      test "records the #{outcome} outcome and returns to idle" do
        state = finish(start_at(0), unquote(outcome), time(@run_duration_ms))

        assert state.phase == :idle
        assert state.last_outcome == %{outcome: unquote(outcome), finished_at: @finished_at}
      end
    end

    test "refuses an outcome while no run is in flight" do
      state = finish(start_at(0), :ok, time(@run_duration_ms))

      assert_raise AssertionError, fn -> finish(state, :ok, time(@run_duration_ms)) end
    end

    test "refuses an outcome it does not know" do
      assert_raise AssertionError, fn -> finish(start_at(0), :unknown, time(0)) end
    end

    test "refuses a time before the run started" do
      assert_raise AssertionError, fn -> finish(start_at(1_000), :ok, time(999)) end
    end
  end

  describe "backoff" do
    for {outcome, index} <- Enum.with_index([:error, :crashed, :deadline_exceeded]) do
      test "a run that ends #{outcome} counts as a failure (case #{index})" do
        state = finish(start_at(0), unquote(outcome), time(@run_duration_ms))

        assert state.failure_count == 1
        assert state.backoff_end_ms == @interval_ms * 2
      end
    end

    # Fails runs in a row under ticks one evaluation period apart, at the
    # vehicle interval and at the agency interval, and measures from the
    # start of the last failed run to the start of the run after it. A
    # scheduler that ticks once per interval and skips 1, 3, 7, then 15 ticks
    # leaves the same time between the two.
    for interval_ms <- [5_000, 60_000],
        {failure_count, interval_count} <- [{1, 1}, {2, 3}, {3, 7}, {4, 15}, {5, 15}] do
      test "#{failure_count} failures in a row at #{interval_ms} ms back off #{interval_count} intervals" do
        interval_ms = unquote(interval_ms)
        {state, start_times_ms} = run_times(unquote(failure_count), :error, interval_ms)
        failed_start_ms = List.last(start_times_ms)

        {_state, start_ms} = tick_until_start(state, failed_start_ms + @period_ms, interval_ms)

        assert start_ms - failed_start_ms == (1 + unquote(interval_count)) * interval_ms
      end
    end

    test "never lasts more intervals than the maximum" do
      {state, start_times_ms} = run_times(12, :error, @interval_ms)

      assert state.failure_count == 12

      assert state.backoff_end_ms ==
               List.last(start_times_ms) +
                 (1 + State.backoff_interval_count_max()) * @interval_ms
    end

    test "is sized by the interval the finish is given" do
      state = finish(start_at(0, 60_000), :error, time(@run_duration_ms, 5_000))

      assert state.backoff_end_ms == 10_000
    end

    test "keeps its length when the interval shortens while it is pending" do
      state = finish(start_at(0), :error, time(@run_duration_ms))

      assert {%{phase: :idle}, :skip} = State.tick(state, time(@interval_ms * 2 - 1, 5_000))
      assert {%{phase: :running}, :start} = State.tick(state, time(@interval_ms * 2, 5_000))
    end

    test "counts from the finish of a run that took longer than the interval" do
      state = finish(start_at(0), :error, time(@interval_ms + 300))

      assert state.backoff_end_ms == @interval_ms * 2 + 300
    end

    test "is cleared when the next run starts" do
      state = finish(start_at(0), :error, time(@run_duration_ms))

      {state, :start} = State.tick(state, time(@interval_ms * 2))

      assert state.backoff_end_ms == nil
    end

    test "a successful run clears the failures" do
      {state, [_first, _second, start_ms]} = run_times(3, :error, @interval_ms)
      {state, start_ms} = tick_until_start(state, start_ms + @period_ms, @interval_ms)

      state = finish(state, :ok, time(start_ms + @run_duration_ms))

      assert state.failure_count == 0
      assert state.backoff_end_ms == nil
    end
  end
end
