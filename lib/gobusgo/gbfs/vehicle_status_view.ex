defmodule Gobusgo.Gbfs.VehicleStatusView do
  @moduledoc """
  The newest fetch of each GBFS system's shared vehicles, held in memory
  for readers. This module owns the process and the table; the rules that
  decide which entry is current live in
  `Gobusgo.Gbfs.VehicleStatusView.State`, and the records it reads in
  `Gobusgo.Gbfs.VehicleStatusBatch.Records`.

  Each system has at most one entry: its newest fetch, whole, or the finding
  that its feed is not published, which holds no vehicle. A fetch with no
  vehicles leaves the system with none. Nothing is keyed on a vehicle
  identifier, so each fetch replaces the one before it whole.

  A view is a process registered under a name and a table of the same name.
  `apply_records/2` hands it record values; `current/2` and `vehicles/2` read
  the table and never wait on the process, so a reader sees a whole fetch or
  the one before it.

  When the current entry of at least one system changes, the view
  announces it once per `apply_records/2` call to the processes that called
  `subscribe/1`, as `{:vehicle_status_view_switched, view}`, after the table
  holds the new entries. A value that is not a record is skipped, and each
  call logs `warning` with the count of skipped values.

  A view starts empty and holds nothing across a restart.
  """

  use GenServer

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Gbfs.VehicleStatusBatch.Records
  alias Gobusgo.Gbfs.VehicleStatusView.State
  alias Gobusgo.Publisher

  @call_timeout_ms 5_000

  @doc """
  Starts a view registered under `options[:name]` for at most
  `options[:system_count_max]` systems, which announces its switches on the
  publish-subscribe server `options[:pubsub]`.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options = Keyword.validate!(options, [:name, :pubsub, :system_count_max])
    name = Keyword.fetch!(options, :name)
    pubsub = Keyword.fetch!(options, :pubsub)
    Assert.condition(is_atom(name), "name must be an atom, got: #{inspect(name)}")
    Assert.condition(is_atom(pubsub), "pubsub must be an atom, got: #{inspect(pubsub)}")

    server = %{
      name: name,
      pubsub: pubsub,
      system_count_max: Keyword.fetch!(options, :system_count_max)
    }

    GenServer.start_link(__MODULE__, server, name: name)
  end

  @doc "The specification of a view as a supervisor's child, with the view's name as its identifier."
  @spec child_spec(Keyword.t()) :: Supervisor.child_spec()
  def child_spec(options) when is_list(options) do
    %{id: Keyword.fetch!(options, :name), start: {__MODULE__, :start_link, [options]}}
  end

  @doc """
  Subscribes the calling process to the switches of `view` on `pubsub`, the
  server the view was started with.
  """
  @spec subscribe(%{view: atom(), pubsub: atom()}) :: :ok
  def subscribe(%{view: view, pubsub: pubsub}) when is_atom(view) and is_atom(pubsub) do
    :ok = Phoenix.PubSub.subscribe(pubsub, topic(view))
  end

  @doc """
  Returns the current entry of `system_id` in `view`, a fetch or a finding
  that the feed is not published as `Gobusgo.Gbfs.VehicleStatusBatch.Records.decode/1`
  returns it, or `nil` for a system with no entry and while the view is not
  running.
  """
  @spec current(atom(), String.t()) :: Records.fetched() | Records.not_published() | nil
  def current(view, system_id) when is_atom(view) and is_binary(system_id) do
    case :ets.whereis(view) do
      :undefined ->
        nil

      table ->
        case :ets.lookup(table, system_id) do
          [{^system_id, entry}] -> entry
          [] -> nil
        end
    end
  end

  @doc """
  Returns the vehicles of the current fetch of `system_id` in `view`: none
  for a system with no fetch, for a feed that is not published, and while
  the view is not running.
  """
  @spec vehicles(atom(), String.t()) :: [Gobusgo.Gbfs.Files.vehicle()]
  def vehicles(view, system_id) when is_atom(view) and is_binary(system_id) do
    case current(view, system_id) do
      %{kind: :fetched, vehicles: vehicles} -> vehicles
      %{kind: :not_published} -> []
      nil -> []
    end
  end

  @doc """
  Applies `values`, at most `Gobusgo.Publisher.record_count_max/0` record
  values, to `view` in order, and returns once the table reflects them.
  Exits when the view does not answer within #{@call_timeout_ms} ms.
  """
  @spec apply_records(atom(), [binary()]) :: :ok
  def apply_records(view, values) when is_atom(view) and is_list(values) do
    count = length(values)

    Assert.condition(
      count <= Publisher.record_count_max(),
      "values must hold at most #{Publisher.record_count_max()} records, got: #{count}"
    )

    GenServer.call(view, {:apply_records, values}, @call_timeout_ms)
  end

  @impl GenServer
  def init(%{name: name, system_count_max: system_count_max} = server) do
    table = :ets.new(name, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, Map.merge(server, %{table: table, state: State.new(system_count_max)})}
  end

  @impl GenServer
  def handle_call({:apply_records, values}, _from, server) do
    counts = %{switched: %{}, invalid: 0}
    {state, counts} = Enum.reduce(values, {server.state, counts}, &apply_value/2)
    true = :ets.insert(server.table, Map.to_list(counts.switched))

    if map_size(counts.switched) >= 1 do
      announce(server)
    end

    if counts.invalid >= 1 do
      Logger.warning("Shared vehicle view skipped invalid records",
        view: inspect(server.name),
        invalid_count: counts.invalid
      )
    end

    {:reply, :ok, %{server | state: state}}
  end

  defp apply_value(value, {state, counts}) do
    case Records.decode(value) do
      {:ok, %{id: id} = entry} ->
        case State.put(state, entry) do
          {state, :switched} -> {state, %{counts | switched: Map.put(counts.switched, id, entry)}}
          {state, :ignored} -> {state, counts}
        end

      {:error, _reason} ->
        {state, %{counts | invalid: counts.invalid + 1}}
    end
  end

  defp announce(%{name: name, pubsub: pubsub}) do
    case Phoenix.PubSub.broadcast(pubsub, topic(name), {:vehicle_status_view_switched, name}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Shared vehicle view switch not announced",
          view: inspect(name),
          reason: inspect(reason)
        )
    end
  end

  defp topic(view), do: "vehicle_status_view:" <> Atom.to_string(view)
end
