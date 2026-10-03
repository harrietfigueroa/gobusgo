defmodule Gobusgo.OneBusAway.RequestGate do
  @refill_interval_ms_default 100
  @in_flight_count_max_default 4
  @waiter_count_max_default 32
  @pause_ms_base_default 1_000
  @pause_ms_max_default 60_000
  @retry_after_ms_max_default 300_000

  @moduledoc """
  The owner of one API key's request budget. A caller takes a permit before
  each request and releases it with the request's outcome. This module owns
  the process, the timer, and the monitors; the rules that decide who gets a
  permit live in `Gobusgo.OneBusAway.RequestGate.State`.

  By default the gate grants one permit every #{@refill_interval_ms_default} ms,
  lets #{@in_flight_count_max_default} permits be held at a time, and lets
  #{@waiter_count_max_default} callers wait. A rate-limited outcome pauses
  every caller: for the time the response names, up to
  #{@retry_after_ms_max_default} ms, or else for a jittered window that
  doubles from #{@pause_ms_base_default} ms to #{@pause_ms_max_default} ms.
  After a pause one caller probes alone, and its completed request reopens
  the gate.

  The gate monitors every caller it knows, so a caller that exits gives up
  its permit or its place among the waiters. State is in memory, and a
  restart begins open, with a full bucket and nobody waiting.

  The gate logs what it decides itself: `warning`
  `OneBusAway request gate paused` with `pause_ms` and `pause_count`, and
  `info` `OneBusAway request gate reopened`.
  """

  use GenServer

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.RequestGate.State

  @type permit :: reference()

  # A waiter is answered by the gate at its deadline; the call's own timeout
  # is this much later, so it fires only when the gate itself is stuck.
  @call_margin_ms 5_000

  @doc """
  Starts a gate. `:name` registers it and is required; `nil` starts it
  without a name. `:refill_interval_ms`, `:in_flight_count_max`,
  `:waiter_count_max`, `:pause_ms_base`, `:pause_ms_max`, and
  `:retry_after_ms_max` replace the defaults above.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options =
      Keyword.validate!(options, [
        :name,
        refill_interval_ms: @refill_interval_ms_default,
        in_flight_count_max: @in_flight_count_max_default,
        waiter_count_max: @waiter_count_max_default,
        pause_ms_base: @pause_ms_base_default,
        pause_ms_max: @pause_ms_max_default,
        retry_after_ms_max: @retry_after_ms_max_default
      ])

    {name, limits} = Keyword.pop!(options, :name)
    Assert.condition(is_atom(name), "name must be an atom, got: #{inspect(name)}")

    case name do
      nil -> GenServer.start_link(__MODULE__, Map.new(limits))
      name -> GenServer.start_link(__MODULE__, Map.new(limits), name: name)
    end
  end

  @doc """
  Takes a permit for the calling process, waiting up to `wait_ms` for one.
  Returns `{:error, :rate_limited}` when the wait runs out, or at once when
  the gate's waiters are at their bound. The caller releases the permit with
  `release/2`; a caller that exits releases it by exiting.
  """
  @spec acquire(GenServer.server(), non_neg_integer()) ::
          {:ok, permit()} | {:error, :rate_limited}
  def acquire(gate, wait_ms) when is_integer(wait_ms) do
    Assert.condition(wait_ms >= 0, "wait_ms must not be negative, got: #{wait_ms}")
    GenServer.call(gate, {:acquire, wait_ms}, wait_ms + @call_margin_ms)
  end

  @doc """
  Releases `permit` with the outcome of its request, a
  `t:Gobusgo.OneBusAway.RequestGate.State.outcome/0`. A permit the gate no
  longer holds changes nothing.
  """
  @spec release(GenServer.server(), %{permit: permit(), outcome: State.outcome()}) :: :ok
  def release(gate, %{permit: permit, outcome: outcome}) when is_reference(permit) do
    GenServer.cast(gate, {:release, permit, outcome})
  end

  @impl GenServer
  def init(limits) do
    {:ok, %{state: State.new(limits), callers: %{}, permits: %{}, timer: nil}}
  end

  @impl GenServer
  def handle_call({:acquire, wait_ms}, {pid, _tag} = from, gate) do
    now_ms = now_ms()
    permit = make_ref()

    case State.enqueue(gate.state, %{id: permit, deadline_at_ms: now_ms + wait_ms}) do
      {:ok, state} ->
        monitor = Process.monitor(pid)

        gate = %{
          gate
          | state: state,
            callers: Map.put(gate.callers, permit, %{from: from, monitor: monitor}),
            permits: Map.put(gate.permits, monitor, permit)
        }

        {:noreply, drain(gate, now_ms)}

      :full ->
        {:reply, {:error, :rate_limited}, gate}
    end
  end

  @impl GenServer
  def handle_cast({:release, permit, outcome}, gate) do
    {:noreply, finish(gate, %{permit: permit, outcome: outcome})}
  end

  @impl GenServer
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, gate) do
    case Map.fetch(gate.permits, monitor) do
      {:ok, permit} -> {:noreply, finish(gate, %{permit: permit, outcome: :failed})}
      :error -> {:noreply, gate}
    end
  end

  def handle_info(:wake, gate) do
    {:noreply, drain(%{gate | timer: nil}, now_ms())}
  end

  defp finish(gate, %{permit: permit, outcome: outcome}) do
    case Map.fetch(gate.callers, permit) do
      {:ok, _caller} ->
        now_ms = now_ms()
        before = gate.state

        state =
          State.release(gate.state, %{
            id: permit,
            outcome: outcome,
            now_ms: now_ms,
            jitter: :rand.uniform()
          })

        log_change(%{before: before, state: state, now_ms: now_ms})
        gate = forget(%{gate | state: state}, permit)
        drain(gate, now_ms)

      :error ->
        gate
    end
  end

  # Grants and expirations are answered here, the one place the timer is set.
  defp drain(gate, now_ms) do
    {state, %{granted: granted, expired: expired}} = State.advance(gate.state, now_ms)
    gate = %{gate | state: state}

    for permit <- granted do
      GenServer.reply(Map.fetch!(gate.callers, permit).from, {:ok, permit})
    end

    gate =
      Enum.reduce(expired, gate, fn permit, gate ->
        GenServer.reply(Map.fetch!(gate.callers, permit).from, {:error, :rate_limited})
        forget(gate, permit)
      end)

    schedule_wake(gate, now_ms)
  end

  defp forget(gate, permit) do
    {%{monitor: monitor}, callers} = Map.pop!(gate.callers, permit)
    Process.demonitor(monitor, [:flush])
    %{gate | callers: callers, permits: Map.delete(gate.permits, monitor)}
  end

  defp schedule_wake(%{timer: timer} = gate, now_ms) do
    case timer do
      nil -> :ok
      timer -> Process.cancel_timer(timer, async: false, info: false)
    end

    case State.wake_at_ms(gate.state) do
      nil ->
        %{gate | timer: nil}

      wake_at_ms ->
        %{gate | timer: Process.send_after(self(), :wake, max(wake_at_ms - now_ms, 0))}
    end
  end

  # A probe that fails without a response returns the gate to a pause that
  # is already over, with the count unchanged; only a new pause is logged.
  defp log_change(%{before: before, state: state, now_ms: now_ms}) do
    pause_count = State.pause_count(state)

    case State.mode(state) do
      {:paused, until_ms} ->
        if pause_count > State.pause_count(before) do
          Logger.warning("OneBusAway request gate paused",
            pause_ms: until_ms - now_ms,
            pause_count: pause_count
          )
        end

      :open ->
        if State.mode(before) != :open do
          Logger.info("OneBusAway request gate reopened")
        end

      {:probing, _permit} ->
        :ok
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
