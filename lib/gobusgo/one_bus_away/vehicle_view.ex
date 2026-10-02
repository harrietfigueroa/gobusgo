defmodule Gobusgo.OneBusAway.VehicleView do
  @moduledoc """
  The vehicles of each agency's latest complete fetch, held in memory for
  readers. This module owns the process and the table; the rules that decide
  which fetch is current live in `Gobusgo.OneBusAway.VehicleView.State`.

  A view is a process registered under a name and a table of the same name.
  `apply_records/2` hands it record values, the bytes
  `Gobusgo.OneBusAway.VehicleBatch.Records` builds; `current/1` reads the
  table and never waits on the process. The table holds each agency's
  current fetch as one entry, so a reader sees a whole fetch of an agency or
  the one before it. Two agencies' fetches are independent of each other and
  carry their own fetch times.

  When the current fetch of at least one agency changes, the view announces
  it once per `apply_records/2` call to the processes that called
  `subscribe/1`, as `{:vehicle_view_switched, view}`, after the table holds
  the new fetches.

  A value that is not a record is skipped. Each call logs `info` when a
  current fetch changed and `warning` with the count of skipped values, and
  `warning` when an announcement could not be sent.

  A view starts empty. It holds nothing across a restart.
  """

  use GenServer

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.VehicleBatch.Records
  alias Gobusgo.OneBusAway.VehicleView.State
  alias Gobusgo.Publisher

  @call_timeout_ms 5_000

  @doc """
  Starts a view registered under `options[:name]` that announces its
  switches on the publish-subscribe server `options[:pubsub]`.
  """
  @spec start_link(name: atom(), pubsub: atom()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options = Keyword.validate!(options, [:name, :pubsub])
    name = Keyword.fetch!(options, :name)
    pubsub = Keyword.fetch!(options, :pubsub)
    Assert.condition(is_atom(name), "name must be an atom, got: #{inspect(name)}")
    Assert.condition(is_atom(pubsub), "pubsub must be an atom, got: #{inspect(pubsub)}")
    GenServer.start_link(__MODULE__, %{name: name, pubsub: pubsub}, name: name)
  end

  @doc """
  Subscribes the calling process to the switches of `view` on `pubsub`, the
  server the view was started with. Each call of `apply_records/2` that
  switches an agency arrives as one `{:vehicle_view_switched, view}`.
  """
  @spec subscribe(%{view: atom(), pubsub: atom()}) :: :ok
  def subscribe(%{view: view, pubsub: pubsub}) when is_atom(view) and is_atom(pubsub) do
    :ok = Phoenix.PubSub.subscribe(pubsub, topic(view))
  end

  @doc """
  Returns the current fetch of every agency of `view` that has one, in
  agency identifier order: each with its `:agency_id`, `:request_id`,
  `:fetched_at`, `:vehicle_ids` in order, and `:vehicles` by identifier.
  Returns `[]` before a fetch is complete and while the view is not running.
  """
  @spec current(atom()) :: [State.fetch()]
  def current(view) when is_atom(view) do
    case :ets.whereis(view) do
      :undefined ->
        []

      table ->
        table
        |> :ets.tab2list()
        |> Enum.sort_by(fn {agency_id, _fetch} -> agency_id end)
        |> Enum.map(fn {_agency_id, fetch} -> fetch end)
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
  def init(%{name: name, pubsub: pubsub}) do
    table = :ets.new(name, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, %{name: name, pubsub: pubsub, table: table, state: State.new()}}
  end

  @impl GenServer
  def handle_call({:apply_records, values}, _from, %{table: table, state: state} = server) do
    {state, counts} =
      Enum.reduce(values, {state, %{switched_agency_ids: [], invalid: 0}}, &apply_value/2)

    switched_agency_ids = Enum.uniq(counts.switched_agency_ids)

    if switched_agency_ids != [] do
      fetches = state |> State.current() |> Map.take(switched_agency_ids)
      true = :ets.insert(table, Map.to_list(fetches))

      Logger.info("Vehicle view switched",
        agency_count: map_size(fetches),
        vehicle_count: fetches |> Map.values() |> Enum.sum_by(&length(&1.vehicle_ids))
      )

      announce(server)
    end

    if counts.invalid >= 1 do
      Logger.warning("Vehicle view skipped invalid records", invalid_count: counts.invalid)
    end

    {:reply, :ok, %{server | state: state}}
  end

  defp announce(%{name: name, pubsub: pubsub}) do
    case Phoenix.PubSub.broadcast(pubsub, topic(name), {:vehicle_view_switched, name}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Vehicle view switch not announced", reason: inspect(reason))
    end
  end

  defp topic(view), do: "vehicle_view:" <> Atom.to_string(view)

  defp apply_value(value, {state, counts}) do
    case Records.decode(value) do
      {:ok, {_kind, %{agency_id: agency_id}} = decoded} ->
        case State.put(state, decoded) do
          {state, :switched} ->
            {state, %{counts | switched_agency_ids: [agency_id | counts.switched_agency_ids]}}

          {state, _outcome} ->
            {state, counts}
        end

      {:error, _reason} ->
        {state, %{counts | invalid: counts.invalid + 1}}
    end
  end
end
