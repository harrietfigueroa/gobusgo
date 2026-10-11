defmodule Gobusgo.Demand do
  @item_count_max_default 2_000
  @holder_item_count_max_default 5
  @call_timeout_ms 5_000

  @moduledoc """
  What the processes of this node want kept fresh: which items of which
  dataset have a process that looks at them. This module owns the process
  and the monitors; the rules live in `Gobusgo.Demand.State`.

  A key is `{dataset, item}`, a dataset the registry was started with and a
  non-empty item of it. A process registers a key with `register/2` and
  releases it with `release/2`. The registry monitors each process that
  holds a key, so a process that exits, a crash included, releases every key
  it held. `items/2` returns the items of a dataset that at least one
  process holds the key of, and `holder_count/2` how many processes hold one
  key. `holding/2` returns that count with how long ago the key last had a
  holder, on the monotonic clock the registry reads at each release, at each
  exit of a holder, and at each `holding/2`.

  The bounds count inside one dataset, so one dataset's demand takes no room
  from another's: by default a dataset has at most
  #{@item_count_max_default} items, and one process holds at most
  #{@holder_item_count_max_default} items of one dataset. A registration
  beyond either bound is refused as a value. The count of processes that
  hold one key has no bound here.

  A call that names a dataset the registry was not started with raises in
  the calling process and leaves the registry as it was.

  State is in memory and per node: a restart begins with no key held and
  no key remembered as having had a holder, and the registry registers
  nothing for the processes that held keys.

  Registering and releasing log nothing: which item a process holds is what
  one rider looks at.
  """

  use GenServer

  alias Gobusgo.Assert
  alias Gobusgo.Demand.State

  @type key :: State.key()

  @type register_error :: :item_count_exceeded | :holder_item_count_exceeded

  @doc """
  Starts a registry. `:name` registers it and `:datasets` lists the datasets
  it admits; both are required. `:item_count_max` and
  `:holder_item_count_max` replace the defaults above. `:monotonic_time_ms`
  is a zero-arity function returning the time in milliseconds on a clock
  that never goes back, by default `System.monotonic_time/1`.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options =
      Keyword.validate!(options, [
        :name,
        :datasets,
        item_count_max: @item_count_max_default,
        holder_item_count_max: @holder_item_count_max_default,
        monotonic_time_ms: &monotonic_time_ms_default/0
      ])

    name = Keyword.fetch!(options, :name)
    Assert.condition(is_atom(name), "name must be an atom, got: #{inspect(name)}")

    monotonic_time_ms = Keyword.fetch!(options, :monotonic_time_ms)

    Assert.condition(
      is_function(monotonic_time_ms, 0),
      "monotonic_time_ms must be a zero-arity function"
    )

    settings = %{
      datasets: Keyword.fetch!(options, :datasets),
      item_count_max: Keyword.fetch!(options, :item_count_max),
      holder_item_count_max: Keyword.fetch!(options, :holder_item_count_max)
    }

    GenServer.start_link(
      __MODULE__,
      %{settings: settings, monotonic_time_ms: monotonic_time_ms},
      name: name
    )
  end

  @doc """
  Registers `key` for the calling process, until it calls `release/2` or
  exits. Registering a key the process holds already is `:ok`.
  """
  @spec register(GenServer.server(), key()) :: :ok | {:error, register_error()}
  def register(registry, {dataset, item} = key) when is_atom(dataset) and is_binary(item) do
    Assert.condition(item != "", "item must be non-empty")
    call(registry, dataset, {:register, key})
  end

  @doc "Releases `key` for the calling process. Returns `:ok` whether or not it held the key."
  @spec release(GenServer.server(), key()) :: :ok
  def release(registry, {dataset, item} = key) when is_atom(dataset) and is_binary(item) do
    call(registry, dataset, {:release, key})
  end

  @doc "Returns the items of `dataset` that at least one process holds the key of, sorted."
  @spec items(GenServer.server(), State.dataset()) :: [String.t()]
  def items(registry, dataset) when is_atom(dataset), do: call(registry, dataset, :items)

  @doc "Returns how many processes hold `key`: the viewers of what the key names."
  @spec holder_count(GenServer.server(), key()) :: non_neg_integer()
  def holder_count(registry, {dataset, item} = key) when is_atom(dataset) and is_binary(item) do
    call(registry, dataset, {:holder_count, key})
  end

  @doc """
  Returns the holders of `key`: `holder_count`, how many processes hold it,
  and `holder_absence_ms`, how long ago it last had a holder, in
  milliseconds. The absence is zero while a process holds the key and `nil`
  for a key that has had no holder for as long as the registry remembers:
  since it started, or since the dataset's bound of remembered items passed
  the key over.
  """
  @spec holding(GenServer.server(), key()) :: State.holding()
  def holding(registry, {dataset, item} = key) when is_atom(dataset) and is_binary(item) do
    call(registry, dataset, {:holding, key})
  end

  defp call(registry, dataset, request) do
    reply = GenServer.call(registry, {dataset, request}, @call_timeout_ms)

    Assert.condition(
      reply != :dataset_unknown,
      "dataset must be one the registry admits, got: #{inspect(dataset)}"
    )

    reply
  end

  @impl GenServer
  def init(%{settings: settings, monotonic_time_ms: monotonic_time_ms}) do
    {:ok, %{state: State.new(settings), monitors: %{}, monotonic_time_ms: monotonic_time_ms}}
  end

  @impl GenServer
  def handle_call({dataset, request}, {pid, _tag}, registry) do
    case State.dataset?(registry.state, dataset) do
      true ->
        {reply, registry} = handle_request(request, dataset, pid, registry)
        {:reply, reply, registry}

      false ->
        {:reply, :dataset_unknown, registry}
    end
  end

  @impl GenServer
  def handle_info({:DOWN, reference, :process, pid, _reason}, registry) do
    case Map.fetch(registry.monitors, pid) do
      {:ok, ^reference} ->
        state = State.release_all(registry.state, %{holder: pid, now_ms: now_ms(registry)})
        {:noreply, %{registry | state: state, monitors: Map.delete(registry.monitors, pid)}}

      _other ->
        {:noreply, registry}
    end
  end

  defp handle_request({:register, key}, _dataset, pid, registry) do
    case State.register(registry.state, %{holder: pid, key: key}) do
      {state, :registered} -> {:ok, monitor(%{registry | state: state}, pid)}
      {_state, :already_registered} -> {:ok, registry}
      {_state, refusal} -> {{:error, refusal}, registry}
    end
  end

  defp handle_request({:release, key}, _dataset, pid, registry) do
    state = State.release(registry.state, %{holder: pid, key: key, now_ms: now_ms(registry)})
    {:ok, demonitor(%{registry | state: state}, pid)}
  end

  defp handle_request(:items, dataset, _pid, registry) do
    {State.items(registry.state, dataset), registry}
  end

  defp handle_request({:holder_count, key}, _dataset, _pid, registry) do
    {State.holder_count(registry.state, key), registry}
  end

  defp handle_request({:holding, key}, _dataset, _pid, registry) do
    {State.holding(registry.state, %{key: key, now_ms: now_ms(registry)}), registry}
  end

  defp now_ms(%{monotonic_time_ms: monotonic_time_ms}) do
    now_ms = monotonic_time_ms.()
    Assert.condition(is_integer(now_ms), "the clock must return an integer")
    now_ms
  end

  defp monotonic_time_ms_default, do: System.monotonic_time(:millisecond)

  defp monitor(%{monitors: monitors} = registry, pid) do
    case is_map_key(monitors, pid) do
      true -> registry
      false -> %{registry | monitors: Map.put(monitors, pid, Process.monitor(pid))}
    end
  end

  # Stops watching a process once it holds no key.
  defp demonitor(%{monitors: monitors, state: state} = registry, pid) do
    case {State.holder?(state, pid), Map.fetch(monitors, pid)} do
      {false, {:ok, reference}} ->
        Process.demonitor(reference, [:flush])
        %{registry | monitors: Map.delete(monitors, pid)}

      _other ->
        registry
    end
  end
end
