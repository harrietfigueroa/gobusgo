defmodule Gobusgo.Scheduler do
  @evaluation_period_ms 1_000
  @signals_wait_ms_default 100

  @moduledoc """
  Runs one source at its cadence. This module owns the process, the timer,
  the clock, and the run in flight; the rules that decide whether a tick
  starts a run live in `Gobusgo.Scheduler.State`.

  A source is described by a spec:

    * `:name`: the name the scheduler is registered under.
    * `:run`: the function to call. It returns `{:ok, term}` or
      `{:error, term}` and logs its own outcome.
    * `:cadence`: how the interval, the time from the start of one run to
      the start of the next, is decided. `:policy` is a policy of
      `Gobusgo.Cadence` whose shortest interval is at least
      #{@evaluation_period_ms}, and `:signals` is a function of no arguments
      that returns the signals the policy decides from, a map.
    * `:deadline_ms`: the longest a run may take before it is killed, under
      the policy's shortest interval, so a run at the fastest cadence ends
      before the next is due.

  The scheduler ticks when it starts and every #{@evaluation_period_ms} ms
  after that, whatever the interval. Each tick reads the signals, asks
  `Gobusgo.Cadence.interval_ms/2` for the interval, reads the monotonic
  clock, and hands the time and the interval to the rules, so a run starts
  within #{@evaluation_period_ms} ms of the interval elapsing since the last
  run started, and the first tick starts the first run. The end of a run
  reads the signals and asks for the interval the same way. A failed run
  delays the next one by a backoff, a duration the rules size from the
  interval.

  The signals function runs in a process of its own, which the scheduler
  waits on for `:signals_wait_ms` and then kills, so a function that stalls
  holds a tick or the end of a run for that long at most. A read fails when
  the function raises, exits, throws, or is killed at the wait. After a
  failed read the scheduler keeps the interval of its last read that worked,
  or the policy's shortest interval when none has, and counts the read.
  Signals that are not a map are a programmer error and stop the scheduler.

  Each run is a task under the given task supervisor, so a run that raises
  or is killed is an outcome and the scheduler keeps running. One run is in
  flight at a time: a tick during a run starts nothing.

  The scheduler logs what it decides itself: `error` `Scheduled run crashed`,
  `error` `Scheduled run exceeded its deadline`, and `warning`
  `Scheduled run overran its interval` once per run, with the count of
  intervals that elapsed during the run as `skipped_interval_count`, and
  `warning` `Scheduler signals read failed` for the first failed read after
  a start or after a read that worked.

  When it stops, the scheduler waits for the run in flight, then kills it.
  State is in memory and a restart begins with nothing counted.
  """

  use GenServer

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Cadence
  alias Gobusgo.Scheduler.State

  @type run_result :: {:ok, term()} | {:error, term()}
  @type cadence :: %{policy: Cadence.policy(), signals: (-> Cadence.signals())}
  @type spec :: %{
          name: atom(),
          run: (-> run_result()),
          cadence: cadence(),
          deadline_ms: pos_integer()
        }
  @type status :: %{
          phase: :idle | :running,
          failure_count: non_neg_integer(),
          run_start_ms: integer() | nil,
          backoff_end_ms: integer() | nil,
          skipped_interval_count: non_neg_integer(),
          run_skipped_interval_count: non_neg_integer(),
          last_outcome: State.finished() | nil,
          interval_ms: pos_integer(),
          signals_failure_count: non_neg_integer()
        }

  @call_timeout_ms 5_000
  @shutdown_margin_ms 5_000
  @shutdown_wait_ms_default 30_000

  @doc "The time between two ticks of a scheduler, in milliseconds."
  @spec evaluation_period_ms() :: pos_integer()
  def evaluation_period_ms, do: @evaluation_period_ms

  @doc """
  Starts the scheduler of `options[:spec]`, with its runs under
  `options[:task_supervisor]`. `:shutdown_wait_ms` is how long a stop waits
  for the run in flight, #{@shutdown_wait_ms_default} by default.
  `:monotonic_time_ms` is a zero-arity function returning the time in
  milliseconds on a clock that never goes back, by default
  `System.monotonic_time/1`. `:signals_wait_ms` is how long one read of the
  signals may take, #{@signals_wait_ms_default} by default and under
  #{@evaluation_period_ms}.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options =
      Keyword.validate!(options, [
        :spec,
        :task_supervisor,
        shutdown_wait_ms: @shutdown_wait_ms_default,
        monotonic_time_ms: &monotonic_time_ms_default/0,
        signals_wait_ms: @signals_wait_ms_default
      ])

    spec = Keyword.fetch!(options, :spec)
    assert_spec(spec)
    shutdown_wait_ms = Keyword.fetch!(options, :shutdown_wait_ms)
    Assert.condition(is_integer(shutdown_wait_ms), "shutdown_wait_ms must be an integer")
    Assert.condition(shutdown_wait_ms >= 0, "shutdown_wait_ms must not be negative")

    Assert.condition(
      is_function(Keyword.fetch!(options, :monotonic_time_ms), 0),
      "monotonic_time_ms must be a zero-arity function"
    )

    signals_wait_ms = Keyword.fetch!(options, :signals_wait_ms)
    assert_duration(signals_wait_ms, "signals_wait_ms")

    Assert.condition(
      signals_wait_ms < @evaluation_period_ms,
      "signals_wait_ms must be under #{@evaluation_period_ms}, got: #{signals_wait_ms}"
    )

    GenServer.start_link(__MODULE__, Map.new(options), name: spec.name)
  end

  @doc """
  Returns `:ok` for a spec a scheduler can run, and raises an assertion
  error for any other: one whose policy `Gobusgo.Cadence.assert_policy/1`
  refuses, whose policy's shortest interval is under
  #{@evaluation_period_ms}, or whose deadline is not under that shortest
  interval.
  """
  @spec assert_spec(spec()) :: :ok
  def assert_spec(spec) do
    Assert.condition(is_map(spec), "spec must be a map")
    Assert.condition(is_atom(spec[:name]), "name must be an atom, got: #{inspect(spec[:name])}")
    Assert.condition(spec[:name] != nil, "name must be given")
    Assert.condition(is_function(spec[:run], 0), "run must be a function of no arguments")

    Assert.condition(
      not is_map_key(spec, :interval_ms),
      "a spec names its interval through its cadence, got interval_ms"
    )

    deadline_ms = spec[:deadline_ms]
    assert_duration(deadline_ms, "deadline_ms")
    cadence = spec[:cadence]
    assert_cadence(cadence)
    interval_ms_min = Cadence.interval_ms_min(cadence.policy)

    Assert.condition(
      deadline_ms < interval_ms_min,
      "deadline_ms must be under the shortest interval #{interval_ms_min}, got: #{deadline_ms}"
    )
  end

  @doc """
  The child specification of one scheduler. Its shutdown time covers the wait
  for the run in flight.
  """
  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(options) when is_list(options) do
    shutdown_wait_ms = Keyword.get(options, :shutdown_wait_ms, @shutdown_wait_ms_default)

    %{
      id: {__MODULE__, Keyword.fetch!(options, :spec).name},
      start: {__MODULE__, :start_link, [options]},
      shutdown: shutdown_wait_ms + @shutdown_margin_ms
    }
  end

  @doc """
  Returns the status of `scheduler`: whether a run is in flight, the failures
  in a row, the intervals skipped during runs, when the last run started and
  a pending backoff ends on the scheduler's clock, how the last run ended,
  the interval the source runs at as `interval_ms`, and the failed reads of
  the signals in a row as `signals_failure_count`. Exits when the scheduler
  does not answer within #{@call_timeout_ms} ms.
  """
  @spec status(atom()) :: status()
  def status(scheduler) when is_atom(scheduler) do
    GenServer.call(scheduler, :status, @call_timeout_ms)
  end

  @impl GenServer
  def init(%{spec: spec, task_supervisor: task_supervisor} = options) do
    # Exits are trapped so that a stop reaches terminate/2, which waits for
    # the run in flight.
    Process.flag(:trap_exit, true)
    send(self(), :tick)

    {:ok,
     %{
       spec: spec,
       task_supervisor: task_supervisor,
       shutdown_wait_ms: options.shutdown_wait_ms,
       monotonic_time_ms: options.monotonic_time_ms,
       signals_wait_ms: options.signals_wait_ms,
       interval_ms: Cadence.interval_ms_min(spec.cadence.policy),
       signals_failure_count: 0,
       state: State.new(),
       run: nil
     }}
  end

  @impl GenServer
  def handle_call(:status, _from, server) do
    status =
      Map.merge(server.state, %{
        interval_ms: server.interval_ms,
        signals_failure_count: server.signals_failure_count
      })

    {:reply, status, server}
  end

  @impl GenServer
  def handle_info(:tick, server) do
    Process.send_after(self(), :tick, @evaluation_period_ms)
    server = read_interval(server)

    case State.tick(server.state, time(server)) do
      {state, :start} ->
        Assert.condition(server.run == nil, "a run must not be in flight at a start")
        {:noreply, %{server | state: state, run: start_run(server)}}

      {state, :skip} ->
        {:noreply, %{server | state: state}}
    end
  end

  def handle_info({reference, result}, %{run: %{task: %Task{ref: reference}}} = server) do
    Process.demonitor(reference, [:flush])
    {:noreply, finish_run(server, outcome(result))}
  end

  def handle_info(
        {:DOWN, reference, :process, _pid, reason},
        %{run: %{task: %Task{ref: reference}}} = server
      ) do
    log_crash(server.spec, reason)
    {:noreply, finish_run(server, :crashed)}
  end

  def handle_info({:deadline, reference}, %{run: %{task: %Task{ref: reference} = task}} = server) do
    case Task.shutdown(task, :brutal_kill) do
      nil ->
        Logger.error("Scheduled run exceeded its deadline",
          source: inspect(server.spec.name),
          deadline_ms: server.spec.deadline_ms
        )

        {:noreply, finish_run(server, :deadline_exceeded)}

      {:ok, result} ->
        {:noreply, finish_run(server, outcome(result))}

      {:exit, reason} ->
        log_crash(server.spec, reason)
        {:noreply, finish_run(server, :crashed)}
    end
  end

  # The deadline of a run that has finished: its timer fired before the
  # cancel in finish_run/2 reached it.
  def handle_info({:deadline, _reference}, server) do
    {:noreply, server}
  end

  @impl GenServer
  def terminate(_reason, %{run: nil}), do: :ok

  def terminate(_reason, %{run: %{task: task}, shutdown_wait_ms: shutdown_wait_ms}) do
    Task.yield(task, shutdown_wait_ms) || Task.shutdown(task, :brutal_kill)
    :ok
  end

  defp start_run(%{spec: spec, task_supervisor: task_supervisor}) do
    task = Task.Supervisor.async_nolink(task_supervisor, spec.run)
    deadline_timer = Process.send_after(self(), {:deadline, task.ref}, spec.deadline_ms)
    %{task: task, deadline_timer: deadline_timer}
  end

  defp finish_run(%{run: %{deadline_timer: deadline_timer}, spec: spec} = server, outcome) do
    Process.cancel_timer(deadline_timer)
    server = read_interval(server)
    finished = %{outcome: outcome, finished_at: DateTime.utc_now()}
    state = State.finish(server.state, finished, time(server))

    if state.run_skipped_interval_count >= 1 do
      Logger.warning("Scheduled run overran its interval",
        source: inspect(spec.name),
        skipped_interval_count: state.run_skipped_interval_count
      )
    end

    %{server | state: state, run: nil}
  end

  defp time(%{interval_ms: interval_ms, monotonic_time_ms: monotonic_time_ms}) do
    now_ms = monotonic_time_ms.()
    Assert.condition(is_integer(now_ms), "the clock must return an integer")
    %{now_ms: now_ms, interval_ms: interval_ms}
  end

  defp read_interval(%{spec: %{cadence: cadence} = spec} = server) do
    case read_signals(cadence.signals, server.signals_wait_ms) do
      {:ok, signals} ->
        interval_ms = Cadence.interval_ms(cadence.policy, signals)

        Assert.condition(
          interval_ms >= @evaluation_period_ms,
          "an interval must be at least #{@evaluation_period_ms}, got: #{interval_ms}"
        )

        %{server | interval_ms: interval_ms, signals_failure_count: 0}

      {:error, reason} ->
        if server.signals_failure_count == 0 do
          Logger.warning("Scheduler signals read failed",
            source: inspect(spec.name),
            interval_ms: server.interval_ms,
            signals_wait_ms: server.signals_wait_ms,
            err: crash_error(reason)
          )
        end

        %{server | signals_failure_count: server.signals_failure_count + 1}
    end
  end

  # The function runs in a process that is neither linked nor a task, so
  # what it raises reaches the scheduler as its exit reason and nowhere
  # else, and a function that never returns is killed at the wait.
  defp read_signals(signals, signals_wait_ms) do
    {reader, monitor} = spawn_monitor(fn -> exit({:signals_read, signals_result(signals)}) end)

    case await_signals(monitor, signals_wait_ms) do
      :timeout ->
        Process.exit(reader, :kill)

        # A reader that finishes as the wait ends is down with its result
        # before the kill reaches it, and this second wait receives it.
        case await_signals(monitor, signals_wait_ms) do
          :timeout ->
            Process.demonitor(monitor, [:flush])
            {:error, :timeout}

          {:error, :killed} ->
            {:error, :timeout}

          result ->
            result
        end

      result ->
        result
    end
  end

  defp await_signals(monitor, signals_wait_ms) do
    receive do
      {:DOWN, ^monitor, :process, _reader, {:signals_read, result}} -> result
      {:DOWN, ^monitor, :process, _reader, reason} -> {:error, reason}
    after
      signals_wait_ms -> :timeout
    end
  end

  defp signals_result(signals) do
    {:ok, signals.()}
  rescue
    exception -> {:error, {exception, __STACKTRACE__}}
  catch
    kind, _value -> {:error, kind}
  end

  defp monotonic_time_ms_default, do: System.monotonic_time(:millisecond)

  defp outcome({:ok, _value}), do: :ok
  defp outcome({:error, _reason}), do: :error
  defp outcome(other), do: Assert.unreachable(other)

  defp log_crash(spec, reason) do
    Logger.error("Scheduled run crashed", source: inspect(spec.name), err: crash_error(reason))
  end

  # An exception's message and a stack frame's arguments can hold the values
  # the run was working on, a credential among them, so the error names the
  # exception and each frame's arity.
  defp crash_error({exception, stacktrace})
       when is_exception(exception) and is_list(stacktrace) do
    %{
      message: inspect(exception.__struct__),
      stack: stacktrace |> Enum.map(&frame_arity/1) |> Exception.format_stacktrace()
    }
  end

  defp crash_error({label, _detail}) when is_atom(label),
    do: %{message: inspect(label), stack: nil}

  defp crash_error(label) when is_atom(label), do: %{message: inspect(label), stack: nil}
  defp crash_error(_reason), do: %{message: "exit", stack: nil}

  defp frame_arity({module, function, arguments, location}) when is_list(arguments) do
    {module, function, length(arguments), location}
  end

  defp frame_arity({function, arguments, location}) when is_list(arguments) do
    {function, length(arguments), location}
  end

  defp frame_arity(frame), do: frame

  defp assert_cadence(cadence) do
    Assert.condition(is_map(cadence), "cadence must be a map, got: #{inspect(cadence)}")

    Assert.condition(
      is_function(cadence[:signals], 0),
      "signals must be a function of no arguments"
    )

    Cadence.assert_policy(cadence[:policy])
    interval_ms_min = Cadence.interval_ms_min(cadence.policy)

    Assert.condition(
      interval_ms_min >= @evaluation_period_ms,
      "a policy's shortest interval must be at least #{@evaluation_period_ms}, got: #{interval_ms_min}"
    )
  end

  defp assert_duration(duration_ms, label) do
    Assert.condition(is_integer(duration_ms), "#{label} must be an integer")
    Assert.condition(duration_ms >= 1, "#{label} must be positive, got: #{duration_ms}")
  end
end
