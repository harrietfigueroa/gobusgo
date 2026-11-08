defmodule Gobusgo.Gbfs.VehicleTiles do
  @system_count_max 8

  @moduledoc """
  The process that holds, per GBFS system, the index of the shared vehicle
  files of its newest fetch, which `Gobusgo.Gbfs.VehicleTiles.Build`
  writes. A page reads the current indexes here and hands their addresses
  to the browser, which reads the files from the static path alone.

  `record/2` makes an index current once every file it names is stored, so
  an index here never names a missing file, and passes over an index of a
  fetch older than the current one. `clear/2` drops a system's index, as
  for a feed that is not published. Either, when it changes what is
  current, announces it once to the processes that called `subscribe/1`,
  as `{:vehicle_tiles_switched, server}`.

  The process holds at most #{@system_count_max} systems, starts empty on
  every start, and holds no vehicle.
  """

  use GenServer

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Gbfs.Systems

  @type server :: GenServer.server()

  @type index :: %{
          system_id: String.t(),
          destination: String.t(),
          fetched_at: DateTime.t(),
          vehicle_count: non_neg_integer()
        }

  @doc "Starts the process. `:name` registers it, and `:pubsub` is the server it announces on."
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options = Keyword.validate!(options, [:name, :pubsub])
    name = Keyword.fetch!(options, :name)
    pubsub = Keyword.fetch!(options, :pubsub)
    Assert.condition(is_atom(name), "name must be an atom, got: #{inspect(name)}")
    Assert.condition(is_atom(pubsub), "pubsub must be an atom, got: #{inspect(pubsub)}")
    GenServer.start_link(__MODULE__, %{name: name, pubsub: pubsub}, name: name)
  end

  @doc "Subscribes the calling process to the switches of `server` on `pubsub`."
  @spec subscribe(%{server: atom(), pubsub: atom()}) :: :ok
  def subscribe(%{server: server, pubsub: pubsub}) when is_atom(server) and is_atom(pubsub) do
    :ok = Phoenix.PubSub.subscribe(pubsub, topic(server))
  end

  @doc "Unsubscribes the calling process from the switches of `server` on `pubsub`."
  @spec unsubscribe(%{server: atom(), pubsub: atom()}) :: :ok
  def unsubscribe(%{server: server, pubsub: pubsub}) when is_atom(server) and is_atom(pubsub) do
    :ok = Phoenix.PubSub.unsubscribe(pubsub, topic(server))
  end

  @doc "The current index of every system that has one, in system order."
  @spec current(server()) :: [index()]
  def current(server), do: GenServer.call(server, :current)

  @doc "Makes `index` its system's current index unless a newer fetch's is current."
  @spec record(server(), index()) :: :ok
  def record(server, %{system_id: system_id, destination: destination} = index)
      when is_binary(destination) do
    Systems.assert_id(system_id)
    %{fetched_at: %DateTime{}, vehicle_count: vehicle_count} = index
    Assert.condition(is_integer(vehicle_count), "vehicle_count must be an integer")
    Assert.condition(vehicle_count >= 0, "vehicle_count must not be negative")
    GenServer.call(server, {:record, index})
  end

  @doc "Drops the current index of `system_id`."
  @spec clear(server(), String.t()) :: :ok
  def clear(server, system_id) do
    Systems.assert_id(system_id)
    GenServer.call(server, {:clear, system_id})
  end

  @impl GenServer
  def init(server), do: {:ok, Map.put(server, :indexes, %{})}

  @impl GenServer
  def handle_call(:current, _from, server) do
    indexes = server.indexes |> Map.values() |> Enum.sort_by(& &1.system_id)
    {:reply, indexes, server}
  end

  def handle_call({:record, %{system_id: system_id} = index}, _from, server) do
    case superseded?(Map.get(server.indexes, system_id), index) do
      true ->
        {:reply, :ok, server}

      false ->
        held_count = map_size(Map.delete(server.indexes, system_id))

        Assert.condition(
          held_count < @system_count_max,
          "the process holds at most #{@system_count_max} systems"
        )

        server = %{server | indexes: Map.put(server.indexes, system_id, index)}
        announce(server)
        {:reply, :ok, server}
    end
  end

  def handle_call({:clear, system_id}, _from, server) do
    case Map.pop(server.indexes, system_id) do
      {nil, _indexes} ->
        {:reply, :ok, server}

      {_index, indexes} ->
        server = %{server | indexes: indexes}
        announce(server)
        {:reply, :ok, server}
    end
  end

  # An index is passed over for the one current already and for any of an
  # older fetch.
  defp superseded?(nil, _index), do: false

  defp superseded?(current, index) do
    same = current.destination == index.destination
    same or DateTime.after?(current.fetched_at, index.fetched_at)
  end

  defp announce(%{name: name, pubsub: pubsub}) do
    case Phoenix.PubSub.broadcast(pubsub, topic(name), {:vehicle_tiles_switched, name}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Shared vehicle tiles switch not announced",
          server: inspect(name),
          reason: inspect(reason)
        )
    end
  end

  defp topic(server), do: "vehicle_tiles:" <> Atom.to_string(server)
end
