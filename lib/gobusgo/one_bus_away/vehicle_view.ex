defmodule Gobusgo.OneBusAway.VehicleView do
  @moduledoc """
  The vehicles of each agency's latest complete fetch, held in memory for
  readers. This module owns the process and the table; the rules that decide
  which fetch is current live in `Gobusgo.OneBusAway.VehicleView.State`.

  The table is the only place that holds a current fetch: the process keeps
  the vehicles of a fetch until it is complete and writes the complete fetch
  to the table.

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

  The table also holds when each vehicle of each agency was last seen, and
  `expired_vehicle_ids/2` reads it the way `current/1` reads the fetches.

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
  alias Gobusgo.RequestId

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
        |> :ets.match_object({{:current, :_}, :_})
        |> Enum.sort_by(fn {{:current, agency_id}, _fetch} -> agency_id end)
        |> Enum.map(fn {_key, fetch} -> fetch end)
    end
  end

  @doc """
  Returns the request identifier of the current fetch of every agency of
  `view` that has one, by agency identifier. It reads no vehicle, so it
  costs the same however many vehicles the fetches hold. Returns `%{}`
  before a fetch is complete and while the view is not running.
  """
  @spec current_request_ids(atom()) :: %{String.t() => RequestId.t()}
  def current_request_ids(view) when is_atom(view) do
    case :ets.whereis(view) do
      :undefined ->
        %{}

      table ->
        table
        |> :ets.select([
          {{{:current, :"$1"}, %{request_id: :"$2"}}, [], [{{:"$1", :"$2"}}]}
        ])
        |> Map.new()
    end
  end

  @doc """
  Returns the current fetch of the agency `agency_id` in `view`, in the form
  `current/1` returns it, or `nil` for an agency that has none and while the
  view is not running.
  """
  @spec current_fetch(atom(), String.t()) :: State.fetch() | nil
  def current_fetch(view, agency_id) when is_atom(view) and is_binary(agency_id) do
    case :ets.whereis(view) do
      :undefined ->
        nil

      table ->
        case :ets.lookup(table, {:current, agency_id}) do
          [{_key, fetch}] -> fetch
          [] -> nil
        end
    end
  end

  @doc """
  Returns the vehicle `vehicle_id` of whichever agency's current fetch in
  `view` holds it, or `nil` for a vehicle no current fetch holds and while
  the view is not running. It reads the one vehicle and no fetch, so it
  costs the same however many vehicles the fetches hold.
  """
  @spec vehicle(atom(), String.t()) :: State.vehicle() | nil
  def vehicle(view, vehicle_id) when is_atom(view) and is_binary(vehicle_id) do
    case :ets.whereis(view) do
      :undefined ->
        nil

      table ->
        held =
          :ets.select(table, [
            {{{:current, :_}, %{vehicles: :"$1"}}, [{:is_map_key, vehicle_id, :"$1"}],
             [{:map_get, vehicle_id, :"$1"}]}
          ])

        case held do
          [vehicle | _others] -> vehicle
          [] -> nil
        end
    end
  end

  @doc """
  Returns, sorted, the vehicles of `fetch.agency_id` in `view` that have
  expired at `fetch`, a fetch made at `fetch.fetched_at` with the vehicles
  `fetch.vehicle_ids`: absent from it, and last seen more than
  `Gobusgo.OneBusAway.VehicleView.State.tombstone_grace_ms/0` before it.
  Returns `[]` for an agency the view has seen no vehicle of and while the
  view is not running.
  """
  @spec expired_vehicle_ids(atom(), %{
          agency_id: String.t(),
          fetched_at: DateTime.t(),
          vehicle_ids: [String.t()]
        }) :: [String.t()]
  def expired_vehicle_ids(view, %{agency_id: agency_id} = fetch)
      when is_atom(view) and is_binary(agency_id) do
    case :ets.whereis(view) do
      :undefined ->
        []

      table ->
        case :ets.lookup(table, {:last_seen, agency_id}) do
          [{_key, last_seen}] -> State.expired_vehicle_ids(last_seen, fetch)
          [] -> []
        end
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
    counts = %{switched_fetches: %{}, seen_agency_ids: [], invalid: 0}
    {state, counts} = Enum.reduce(values, {state, counts}, &apply_value/2)
    %{switched_fetches: switched_fetches} = counts
    seen_agency_ids = Enum.uniq(counts.seen_agency_ids ++ Map.keys(switched_fetches))
    last_seen = state |> State.last_seen() |> Map.take(seen_agency_ids)
    true = :ets.insert(table, for({id, seen} <- last_seen, do: {{:last_seen, id}, seen}))

    if map_size(switched_fetches) >= 1 do
      true = :ets.insert(table, for({id, fetch} <- switched_fetches, do: {{:current, id}, fetch}))

      Logger.info("Vehicle view switched",
        agency_count: map_size(switched_fetches),
        vehicle_count: switched_fetches |> Map.values() |> Enum.sum_by(&length(&1.vehicle_ids))
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
      {:ok, {kind, %{agency_id: agency_id}} = decoded} ->
        counts = see(counts, kind, agency_id)

        case State.put(state, decoded) do
          {state, {:switched, %{agency_id: fetch_agency_id} = fetch}} ->
            Assert.condition(
              fetch_agency_id == agency_id,
              "fetch must be of the record's agency #{inspect(agency_id)}, got: #{inspect(fetch_agency_id)}"
            )

            # A later fetch of the agency in the same call replaces this one.
            {state,
             %{counts | switched_fetches: Map.put(counts.switched_fetches, agency_id, fetch)}}

          {state, _outcome} ->
            {state, counts}
        end

      {:error, _reason} ->
        {state, %{counts | invalid: counts.invalid + 1}}
    end
  end

  defp see(counts, :manifest, _agency_id), do: counts

  defp see(counts, :vehicle, agency_id) do
    %{counts | seen_agency_ids: [agency_id | counts.seen_agency_ids]}
  end
end
