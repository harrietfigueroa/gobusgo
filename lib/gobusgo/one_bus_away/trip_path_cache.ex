defmodule Gobusgo.OneBusAway.TripPathCache do
  @call_timeout_ms 5_000

  @moduledoc """
  The trip paths built so far, by trip identifier and service date, held in
  memory for every page of the node. This module owns the process and the
  table; `Gobusgo.OneBusAway.TripPathCache.State` holds the bound.

  A cache is a process registered under a name and a table of the same
  name. `lookup/2` and `count/1` read the table and never wait on the
  process; `put/2` waits for it. The cache holds at most its
  `trip_count_max` paths, and a path past the bound evicts the one put
  earliest. A value is held as it is put, so a path's encoded text, a
  binary of more than 64 bytes, lives outside the table and is shared with
  every reader rather than copied.

  A cache starts empty and holds nothing across a restart.
  """

  use GenServer

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.TripPathCache.State

  @doc """
  Starts a cache registered under `options[:name]`, holding at most
  `options[:trip_count_max]` paths.
  """
  @spec start_link(name: atom(), trip_count_max: pos_integer()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    name = Keyword.fetch!(options, :name)
    Assert.condition(is_atom(name), "name must be an atom")
    state = State.new(%{trip_count_max: Keyword.fetch!(options, :trip_count_max)})
    GenServer.start_link(__MODULE__, %{name: name, state: state}, name: name)
  end

  @doc "The specification of a cache as a supervisor's child, with the cache's name as its identifier."
  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(options) when is_list(options) do
    %{id: Keyword.fetch!(options, :name), start: {__MODULE__, :start_link, [options]}}
  end

  @doc """
  Returns the value put under `key` in `cache`, or `nil` for a key the
  cache does not hold and while the cache is not running.
  """
  @spec lookup(atom(), State.key()) :: term() | nil
  def lookup(cache, key) when is_atom(cache) do
    case :ets.whereis(cache) do
      :undefined ->
        nil

      table ->
        case :ets.lookup(table, key) do
          [{^key, value}] -> value
          [] -> nil
        end
    end
  end

  @doc "Returns the count of paths `cache` holds, and 0 while it is not running."
  @spec count(atom()) :: non_neg_integer()
  def count(cache) when is_atom(cache) do
    case :ets.whereis(cache) do
      :undefined -> 0
      table -> :ets.info(table, :size)
    end
  end

  @doc """
  Puts each `{key, value}` of `entries` in `cache`, in order, and returns
  once `lookup/2` reads them. Exits when the cache does not answer within
  #{@call_timeout_ms} ms.
  """
  @spec put(atom(), [{State.key(), term()}]) :: :ok
  def put(cache, entries) when is_atom(cache) and is_list(entries) do
    GenServer.call(cache, {:put, entries}, @call_timeout_ms)
  end

  @impl GenServer
  def init(%{name: name} = server) do
    table = :ets.new(name, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, Map.put(server, :table, table)}
  end

  @impl GenServer
  def handle_call({:put, entries}, _from, %{table: table} = server) do
    state =
      Enum.reduce(entries, server.state, fn {key, value}, state ->
        {state, evicted} = State.put(state, key)
        true = :ets.insert(table, {key, value})
        Enum.each(evicted, &:ets.delete(table, &1))
        state
      end)

    Assert.condition(
      :ets.info(table, :size) == State.count(state),
      "the table holds exactly the keys the state counts"
    )

    {:reply, :ok, %{server | state: state}}
  end
end
