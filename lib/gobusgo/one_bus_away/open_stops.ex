defmodule Gobusgo.OneBusAway.OpenStops do
  @stop_count_max_default 2_000
  @opener_stop_count_max_default 4
  @call_timeout_ms 5_000

  @moduledoc """
  The stops that processes of this node have open, which is what the
  arrivals cycle fetches. This module owns the process and the monitors; the
  rules live in `Gobusgo.OneBusAway.OpenStops.State`.

  A process opens a stop with `open/2` and closes it with `close/2`. The
  registry monitors each process that has a stop open, so a process that
  exits closes every stop it had open. `stop_ids/1` returns the stops at
  least one process has open.

  By default at most #{@stop_count_max_default} stops are open and one
  process has at most #{@opener_stop_count_max_default} open. State is in
  memory and per node: a restart begins with no stop open, and the processes
  that had stops open do not open them again by themselves.

  Opening and closing log nothing: which stop a process opens is what one
  rider looks at.
  """

  use GenServer

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.OpenStops.State

  @type open_error :: :stop_count_exceeded | :opener_stop_count_exceeded

  @doc """
  Starts a registry. `:name` registers it and is required.
  `:stop_count_max` and `:opener_stop_count_max` replace the defaults above.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options =
      Keyword.validate!(options, [
        :name,
        stop_count_max: @stop_count_max_default,
        opener_stop_count_max: @opener_stop_count_max_default
      ])

    name = Keyword.fetch!(options, :name)
    Assert.condition(is_atom(name), "name must be an atom, got: #{inspect(name)}")

    bounds = %{
      stop_count_max: Keyword.fetch!(options, :stop_count_max),
      opener_stop_count_max: Keyword.fetch!(options, :opener_stop_count_max)
    }

    GenServer.start_link(__MODULE__, bounds, name: name)
  end

  @doc """
  Opens the stop `stop_id` for the calling process, until it calls `close/2`
  or exits. Opening a stop the process has open already is `:ok`.
  """
  @spec open(GenServer.server(), String.t()) :: :ok | {:error, open_error()}
  def open(registry, stop_id) when is_binary(stop_id) do
    Assert.condition(stop_id != "", "stop identifier must be non-empty")
    GenServer.call(registry, {:open, stop_id}, @call_timeout_ms)
  end

  @doc "Closes the stop `stop_id` for the calling process. Returns `:ok` whether or not it was open."
  @spec close(GenServer.server(), String.t()) :: :ok
  def close(registry, stop_id) when is_binary(stop_id) do
    GenServer.call(registry, {:close, stop_id}, @call_timeout_ms)
  end

  @doc "Returns the stops at least one process has open, sorted."
  @spec stop_ids(GenServer.server()) :: [String.t()]
  def stop_ids(registry), do: GenServer.call(registry, :stop_ids, @call_timeout_ms)

  @impl GenServer
  def init(bounds), do: {:ok, %{state: State.new(bounds), monitors: %{}}}

  @impl GenServer
  def handle_call({:open, stop_id}, {pid, _tag}, registry) do
    case State.open(registry.state, %{opener: pid, stop_id: stop_id}) do
      {state, :opened} -> {:reply, :ok, monitor(%{registry | state: state}, pid)}
      {_state, :already_open} -> {:reply, :ok, registry}
      {_state, refusal} -> {:reply, {:error, refusal}, registry}
    end
  end

  def handle_call({:close, stop_id}, {pid, _tag}, registry) do
    state = State.close(registry.state, %{opener: pid, stop_id: stop_id})
    {:reply, :ok, demonitor(%{registry | state: state}, pid)}
  end

  def handle_call(:stop_ids, _from, registry) do
    {:reply, State.stop_ids(registry.state), registry}
  end

  @impl GenServer
  def handle_info({:DOWN, reference, :process, pid, _reason}, registry) do
    case Map.fetch(registry.monitors, pid) do
      {:ok, ^reference} ->
        state = State.close_all(registry.state, pid)
        {:noreply, %{registry | state: state, monitors: Map.delete(registry.monitors, pid)}}

      _other ->
        {:noreply, registry}
    end
  end

  defp monitor(%{monitors: monitors} = registry, pid) do
    case is_map_key(monitors, pid) do
      true -> registry
      false -> %{registry | monitors: Map.put(monitors, pid, Process.monitor(pid))}
    end
  end

  # Stops watching a process once it has no stop open.
  defp demonitor(%{monitors: monitors, state: state} = registry, pid) do
    case {State.opener?(state, pid), Map.fetch(monitors, pid)} do
      {false, {:ok, reference}} ->
        Process.demonitor(reference, [:flush])
        %{registry | monitors: Map.delete(monitors, pid)}

      _other ->
        registry
    end
  end
end
