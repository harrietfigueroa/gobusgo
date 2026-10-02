defmodule Gobusgo.Scheduler do
  @moduledoc """
  Runs one source at its cadence. This module owns the process, the timer,
  and the run in flight; the rules that decide whether a tick starts a run
  live in `Gobusgo.Scheduler.State`.

  A source is described by a spec:

    * `:name`: the name the scheduler is registered under.
    * `:run`: the function to call. It returns `{:ok, term}` or
      `{:error, term}` and logs its own outcome.
    * `:interval_ms`: the time between ticks.
    * `:deadline_ms`: the longest a run may take before it is killed.

  The first tick comes when the scheduler starts. Each run is a task under
  the given task supervisor, so a run that raises or is killed is an outcome
  and the scheduler keeps running. One run is in flight at a time: a tick
  during a run is skipped and counted.

  The scheduler logs what it decides itself: `error` `Scheduled run crashed`,
  `error` `Scheduled run exceeded its deadline`, and `warning`
  `Scheduled run overran its interval` once per run with the count of
  skipped ticks.

  When it stops, the scheduler waits for the run in flight, then kills it.
  State is in memory and a restart begins with nothing counted.
  """

  use GenServer

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Scheduler.State

  @type run_result :: {:ok, term()} | {:error, term()}
  @type spec :: %{
          name: atom(),
          run: (-> run_result()),
          interval_ms: pos_integer(),
          deadline_ms: pos_integer()
        }

  @call_timeout_ms 5_000
  @shutdown_margin_ms 5_000
  @shutdown_wait_ms_default 30_000

  @doc """
  Starts the scheduler of `options[:spec]`, with its runs under
  `options[:task_supervisor]`. `:shutdown_wait_ms` is how long a stop waits
  for the run in flight, #{@shutdown_wait_ms_default} by default.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options =
      Keyword.validate!(options, [
        :spec,
        :task_supervisor,
        shutdown_wait_ms: @shutdown_wait_ms_default
      ])

    spec = Keyword.fetch!(options, :spec)
    assert_spec(spec)
    shutdown_wait_ms = Keyword.fetch!(options, :shutdown_wait_ms)
    Assert.condition(is_integer(shutdown_wait_ms), "shutdown_wait_ms must be an integer")
    Assert.condition(shutdown_wait_ms >= 0, "shutdown_wait_ms must not be negative")

    GenServer.start_link(__MODULE__, Map.new(options), name: spec.name)
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
  in a row, the ticks skipped, and how the last run ended. Exits when the
  scheduler does not answer within #{@call_timeout_ms} ms.
  """
  @spec status(atom()) :: State.t()
  def status(scheduler) when is_atom(scheduler) do
    GenServer.call(scheduler, :status, @call_timeout_ms)
  end

  @impl GenServer
  def init(%{spec: spec, task_supervisor: task_supervisor, shutdown_wait_ms: shutdown_wait_ms}) do
    # Exits are trapped so that a stop reaches terminate/2, which waits for
    # the run in flight.
    Process.flag(:trap_exit, true)
    send(self(), :tick)

    {:ok,
     %{
       spec: spec,
       task_supervisor: task_supervisor,
       shutdown_wait_ms: shutdown_wait_ms,
       state: State.new(),
       run: nil
     }}
  end

  @impl GenServer
  def handle_call(:status, _from, server) do
    {:reply, server.state, server}
  end

  @impl GenServer
  def handle_info(:tick, %{spec: spec} = server) do
    Process.send_after(self(), :tick, spec.interval_ms)

    case State.tick(server.state) do
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
    run_skipped_tick_count = server.state.run_skipped_tick_count

    if run_skipped_tick_count >= 1 do
      Logger.warning("Scheduled run overran its interval",
        source: inspect(spec.name),
        skipped_tick_count: run_skipped_tick_count
      )
    end

    finished = %{outcome: outcome, finished_at: DateTime.utc_now()}
    %{server | state: State.finish(server.state, finished), run: nil}
  end

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

  defp assert_spec(spec) do
    Assert.condition(is_map(spec), "spec must be a map")
    Assert.condition(is_atom(spec.name), "name must be an atom, got: #{inspect(spec.name)}")
    Assert.condition(is_function(spec.run, 0), "run must be a function of no arguments")
    assert_duration(spec.interval_ms, "interval_ms")
    assert_duration(spec.deadline_ms, "deadline_ms")
  end

  defp assert_duration(duration_ms, label) do
    Assert.condition(is_integer(duration_ms), "#{label} must be an integer")
    Assert.condition(duration_ms >= 1, "#{label} must be positive, got: #{duration_ms}")
  end
end
