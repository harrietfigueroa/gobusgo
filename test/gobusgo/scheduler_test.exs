defmodule Gobusgo.SchedulerTest do
  # Starts a scheduler per test on a clock the test owns, which stands still
  # until the test advances it, so a timer tick changes nothing by itself.
  # After advancing the clock a test sends the `:tick` message the timer
  # sends, and the scheduler evaluates the new time at once. Each run is a
  # function defined here that reports to the test and waits for the test's
  # instruction, so a run is in flight for exactly as long as the test wants.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.Scheduler

  @moduletag capture_log: true

  @interval_ms 3_600_000
  @deadline_ms 60_000
  @receive_timeout_ms 1_000

  setup context do
    task_supervisor = Module.concat(__MODULE__, "TaskSupervisor#{context.line}")
    start_supervised!({Task.Supervisor, name: task_supervisor, max_children: 1})

    %{
      name: Module.concat(__MODULE__, "Scheduler#{context.line}"),
      task_supervisor: task_supervisor,
      clock: :atomics.new(1, signed: true)
    }
  end

  # The call returns once the scheduler has handled every message sent to it
  # so far, the end of a run among them, so each of those is handled at the
  # time before the advance.
  defp advance_clock(context, duration_ms) do
    Scheduler.status(context.name)
    :atomics.add(context.clock, 1, duration_ms)
  end

  # Advances the clock and has the scheduler evaluate the new time.
  defp tick_after(context, duration_ms) do
    advance_clock(context, duration_ms)
    send(Process.whereis(context.name), :tick)
  end

  # A run that tells the test it started, then does what the test sends it.
  defp run(test) do
    fn ->
      send(test, {:run_started, self()})

      receive do
        {:return, value} -> value
        :raise -> raise "run failed"
      end
    end
  end

  defp start_scheduler(context, overrides \\ %{}) do
    spec =
      Map.merge(
        %{
          name: context.name,
          run: run(self()),
          interval_ms: @interval_ms,
          deadline_ms: @deadline_ms
        },
        Map.get(overrides, :spec, %{})
      )

    # A test that ends with its run in flight stops the scheduler without a
    # wait, so the suite never sits out the default.
    options =
      Keyword.merge(
        [
          spec: spec,
          task_supervisor: context.task_supervisor,
          shutdown_wait_ms: 0,
          monotonic_time_ms: fn -> :atomics.get(context.clock, 1) end
        ],
        Map.get(overrides, :options, [])
      )

    start_supervised!({Scheduler, options})
  end

  defp await_run_start do
    assert_receive {:run_started, run}, @receive_timeout_ms
    Process.monitor(run)
    run
  end

  # Ends the run and waits until its process is gone, by which time its reply
  # or its exit is in the scheduler's mailbox ahead of any later call.
  defp end_run(run, instruction) do
    send(run, instruction)
    assert_receive {:DOWN, _reference, :process, ^run, _reason}, @receive_timeout_ms
  end

  describe "a run" do
    test "starts when the scheduler starts", context do
      start_scheduler(context)

      await_run_start()
      assert %{phase: :running, last_outcome: nil} = Scheduler.status(context.name)
    end

    test "that returns ok is the last outcome", context do
      start_scheduler(context)
      run = await_run_start()

      end_run(run, {:return, {:ok, :recorded}})

      assert %{phase: :idle, failure_count: 0, last_outcome: %{outcome: :ok}} =
               Scheduler.status(context.name)
    end

    test "that returns an error is a failure", context do
      start_scheduler(context)
      run = await_run_start()

      end_run(run, {:return, {:error, :unavailable}})

      assert %{phase: :idle, failure_count: 1, last_outcome: %{outcome: :error}} =
               Scheduler.status(context.name)
    end

    test "records when it finished", context do
      start_scheduler(context)
      run = await_run_start()

      end_run(run, {:return, {:ok, :recorded}})

      assert %{last_outcome: %{finished_at: %DateTime{time_zone: "Etc/UTC"}}} =
               Scheduler.status(context.name)
    end

    test "does not start again before the interval has elapsed", context do
      start_scheduler(context)
      run = await_run_start()
      end_run(run, {:return, {:ok, :recorded}})

      tick_after(context, @interval_ms - 1)

      assert %{phase: :idle} = Scheduler.status(context.name)
      refute_received {:run_started, _run}
    end

    test "starts again once the interval has elapsed since it started", context do
      start_scheduler(context)
      run = await_run_start()
      end_run(run, {:return, {:ok, :recorded}})

      tick_after(context, @interval_ms)

      assert await_run_start() != run
    end

    # Advances the clock and sends no tick, so the run can only come from
    # the scheduler's own timer, and waits one evaluation period for it.
    test "starts within one evaluation period of the interval elapsing", context do
      start_scheduler(context)
      run = await_run_start()
      end_run(run, {:return, {:ok, :recorded}})

      advance_clock(context, @interval_ms)

      period_ms = Scheduler.evaluation_period_ms()
      assert_receive {:run_started, next_run}, period_ms + @receive_timeout_ms
      assert next_run != run
    end
  end

  describe "a run that crashes" do
    test "is a failure and leaves the scheduler running", context do
      scheduler = start_scheduler(context)
      run = await_run_start()

      end_run(run, :raise)

      assert %{phase: :idle, failure_count: 1, last_outcome: %{outcome: :crashed}} =
               Scheduler.status(context.name)

      assert Process.whereis(context.name) == scheduler
    end

    test "is logged as an error with its source", context do
      log =
        capture_log([metadata: :all], fn ->
          start_scheduler(context)
          run = await_run_start()
          end_run(run, :raise)
          Scheduler.status(context.name)
        end)

      assert log =~ "[error] Scheduled run crashed"
      assert log =~ "source=#{inspect(context.name)}"
    end

    test "is not followed by a run while its backoff is pending", context do
      start_scheduler(context)
      run = await_run_start()
      end_run(run, :raise)

      tick_after(context, @interval_ms * 2 - 1)

      assert %{phase: :idle, failure_count: 1} = Scheduler.status(context.name)
      refute_received {:run_started, _run}
    end

    test "is followed by a run once its backoff of one interval has passed", context do
      start_scheduler(context)
      run = await_run_start()
      end_run(run, :raise)

      tick_after(context, @interval_ms * 2)

      assert await_run_start() != run
    end
  end

  describe "a run that is killed" do
    test "is a failure and leaves the scheduler running", context do
      scheduler = start_scheduler(context)
      run = await_run_start()

      Process.exit(run, :kill)
      assert_receive {:DOWN, _reference, :process, ^run, :killed}, @receive_timeout_ms

      assert %{phase: :idle, last_outcome: %{outcome: :crashed}} = Scheduler.status(context.name)
      assert Process.whereis(context.name) == scheduler
    end
  end

  describe "a tick during a run" do
    test "starts nothing, and counts the intervals that have elapsed", context do
      start_scheduler(context)
      await_run_start()

      tick_after(context, @interval_ms)
      tick_after(context, @interval_ms)

      assert %{phase: :running, skipped_interval_count: 2} = Scheduler.status(context.name)
      refute_received {:run_started, _run}
    end

    test "inside the run's first interval counts nothing", context do
      start_scheduler(context)
      await_run_start()

      tick_after(context, @interval_ms - 1)

      assert %{phase: :running, skipped_interval_count: 0} = Scheduler.status(context.name)
    end
  end

  describe "a run that overruns its interval" do
    test "is logged once as a warning with the count of intervals", context do
      log =
        capture_log([metadata: :all], fn ->
          start_scheduler(context)
          run = await_run_start()
          tick_after(context, @interval_ms)
          tick_after(context, @interval_ms)
          Scheduler.status(context.name)
          end_run(run, {:return, {:ok, :recorded}})
          Scheduler.status(context.name)
        end)

      assert log =~ "[warning] Scheduled run overran its interval"
      assert log =~ "skipped_interval_count=2"
      assert length(String.split(log, "Scheduled run overran its interval")) == 2
    end

    test "is not logged when the run ends inside its interval", context do
      log =
        capture_log([metadata: :all], fn ->
          start_scheduler(context)
          run = await_run_start()
          tick_after(context, @interval_ms - 1)
          end_run(run, {:return, {:ok, :recorded}})
          Scheduler.status(context.name)
        end)

      refute log =~ "Scheduled run overran its interval"
    end
  end

  describe "a run past its deadline" do
    test "is killed and is a failure", context do
      start_scheduler(context, %{spec: %{deadline_ms: 10}})
      run = await_run_start()

      assert_receive {:DOWN, _reference, :process, ^run, :killed}, @receive_timeout_ms

      assert %{phase: :idle, failure_count: 1, last_outcome: %{outcome: :deadline_exceeded}} =
               Scheduler.status(context.name)
    end

    test "is logged as an error with the deadline", context do
      log =
        capture_log([metadata: :all], fn ->
          start_scheduler(context, %{spec: %{deadline_ms: 10}})
          run = await_run_start()
          assert_receive {:DOWN, _reference, :process, ^run, :killed}, @receive_timeout_ms
          Scheduler.status(context.name)
        end)

      assert log =~ "[error] Scheduled run exceeded its deadline"
      assert log =~ "deadline_ms=10"
    end
  end

  describe "stopping" do
    test "waits for the run in flight", context do
      scheduler = start_scheduler(context, %{options: [shutdown_wait_ms: @receive_timeout_ms]})
      run = await_run_start()

      stop = Task.async(fn -> GenServer.stop(scheduler, :shutdown) end)
      assert Task.yield(stop, 50) == nil
      send(run, {:return, {:ok, :recorded}})

      assert Task.await(stop, @receive_timeout_ms) == :ok
      assert_receive {:DOWN, _reference, :process, ^run, :normal}, @receive_timeout_ms
    end

    test "kills a run still in flight after the wait", context do
      scheduler = start_scheduler(context, %{options: [shutdown_wait_ms: 10]})
      run = await_run_start()

      assert GenServer.stop(scheduler, :shutdown) == :ok

      assert_receive {:DOWN, _reference, :process, ^run, :killed}, @receive_timeout_ms
    end
  end

  describe "start_link/1" do
    for {field, value} <- [
          interval_ms: 0,
          interval_ms: 999,
          deadline_ms: 0,
          interval_ms: 1.5,
          run: :not_a_function
        ] do
      test "refuses a spec whose #{field} is #{inspect(value)}", context do
        spec = %{
          name: context.name,
          run: fn -> {:ok, :recorded} end,
          interval_ms: @interval_ms,
          deadline_ms: @deadline_ms
        }

        spec = Map.put(spec, unquote(field), unquote(value))

        assert_raise Gobusgo.Assert.AssertionError, fn ->
          Scheduler.start_link(spec: spec, task_supervisor: context.task_supervisor)
        end
      end
    end

    test "refuses a clock that is not a zero-arity function", context do
      spec = %{
        name: context.name,
        run: fn -> {:ok, :recorded} end,
        interval_ms: @interval_ms,
        deadline_ms: @deadline_ms
      }

      assert_raise Gobusgo.Assert.AssertionError, fn ->
        Scheduler.start_link(
          spec: spec,
          task_supervisor: context.task_supervisor,
          monotonic_time_ms: :not_a_function
        )
      end
    end
  end

  describe "evaluation_period_ms/0" do
    test "is one second" do
      assert Scheduler.evaluation_period_ms() == 1_000
    end
  end
end
