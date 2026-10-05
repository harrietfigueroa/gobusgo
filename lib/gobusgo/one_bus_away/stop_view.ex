defmodule Gobusgo.OneBusAway.StopView do
  @moduledoc """
  The stops the current fetches of the routes list, held in memory for
  readers. This module owns the process and the table; the rules that decide
  which stops are held live in `Gobusgo.OneBusAway.StopView.State`.

  A view is a process registered under a name and a table of the same name.
  `apply_records/2` hands it record values, each the stops of one route's
  fetch as `Gobusgo.OneBusAway.RoutePathBatch.StopRecords` builds it;
  `current/1`, `stop/2`, and `stop_count/1` read the table and never wait on
  the process. The table holds each stop as one entry, so a reader sees a
  whole stop. A reader of several stops during a call of `apply_records/2`
  can see some of a fetch's stops before the others.

  When a call of `apply_records/2` holds or removes at least one stop, the
  view announces it once to the processes that called `subscribe/1`, as
  `{:stop_view_switched, view}`, after the table reflects the call.

  A record of another type is passed over and not counted. Any other value
  that is not a record is skipped, and a fetch that would hold more stops
  than the view's bound is refused. Each call logs `debug` when a stop
  changed, `warning` with the count of skipped values, `warning` with the
  count of refused fetches, and `warning` when an announcement could not be
  sent.

  A view starts empty. It holds nothing across a restart.
  """

  use GenServer

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.RoutePathBatch.StopRecords
  alias Gobusgo.OneBusAway.StopView.State
  alias Gobusgo.Publisher

  @call_timeout_ms 5_000

  @doc """
  Starts a view registered under `options[:name]`, holding the stops of at
  most `options[:route_count_max]` routes and at most
  `options[:stop_count_max]` stops, that announces its switches on the
  publish-subscribe server `options[:pubsub]`.
  """
  @spec start_link(
          name: atom(),
          pubsub: atom(),
          route_count_max: pos_integer(),
          stop_count_max: pos_integer()
        ) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options = Keyword.validate!(options, [:name, :pubsub, :route_count_max, :stop_count_max])
    name = Keyword.fetch!(options, :name)
    pubsub = Keyword.fetch!(options, :pubsub)
    Assert.condition(is_atom(name), "name must be an atom, got: #{inspect(name)}")
    Assert.condition(is_atom(pubsub), "pubsub must be an atom, got: #{inspect(pubsub)}")

    server = %{
      name: name,
      pubsub: pubsub,
      bounds: %{
        route_count_max: Keyword.fetch!(options, :route_count_max),
        stop_count_max: Keyword.fetch!(options, :stop_count_max)
      }
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
  server the view was started with. Each call of `apply_records/2` that
  holds or removes a stop arrives as one `{:stop_view_switched, view}`.
  """
  @spec subscribe(%{view: atom(), pubsub: atom()}) :: :ok
  def subscribe(%{view: view, pubsub: pubsub}) when is_atom(view) and is_atom(pubsub) do
    :ok = Phoenix.PubSub.subscribe(pubsub, topic(view))
  end

  @doc """
  Returns every stop `view` holds, in identifier order, each with the fetch
  its values come from. Returns `[]` before a fetch arrives and while the
  view is not running.
  """
  @spec current(atom()) :: [State.held_stop()]
  def current(view) when is_atom(view) do
    case :ets.whereis(view) do
      :undefined ->
        []

      table ->
        table
        |> :ets.tab2list()
        |> Enum.sort_by(fn {id, _held_stop} -> id end)
        |> Enum.map(fn {_id, held_stop} -> held_stop end)
    end
  end

  @doc """
  Returns the stop `id` in `view` with the fetch its values come from, or
  `nil` for a stop the view does not hold and while the view is not running.
  """
  @spec stop(atom(), String.t()) :: State.held_stop() | nil
  def stop(view, id) when is_atom(view) and is_binary(id) do
    case :ets.whereis(view) do
      :undefined ->
        nil

      table ->
        case :ets.lookup(table, id) do
          [{^id, held_stop}] -> held_stop
          [] -> nil
        end
    end
  end

  @doc "Returns the number of stops `view` holds, `0` while the view is not running."
  @spec stop_count(atom()) :: non_neg_integer()
  def stop_count(view) when is_atom(view) do
    case :ets.whereis(view) do
      :undefined -> 0
      table -> :ets.info(table, :size)
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
  def init(%{name: name, bounds: bounds} = server) do
    table = :ets.new(name, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, server |> Map.put(:table, table) |> Map.put(:state, State.new(bounds))}
  end

  @impl GenServer
  def handle_call({:apply_records, values}, _from, %{name: name} = server) do
    counts = %{switched: 0, changed: 0, invalid: 0, refused: 0}
    {state, counts} = Enum.reduce(values, {server.state, counts}, &apply_value(&1, &2, server))

    if counts.changed >= 1 do
      Logger.debug("Stop view switched",
        view: inspect(name),
        route_count: counts.switched,
        stop_count: State.stop_count(state)
      )

      announce(server)
    end

    if counts.invalid >= 1 do
      Logger.warning("Stop view skipped invalid records",
        view: inspect(name),
        invalid_count: counts.invalid
      )
    end

    if counts.refused >= 1 do
      Logger.warning("Stop view refused fetches beyond its stop bound",
        view: inspect(name),
        refused_count: counts.refused,
        stop_count_max: server.bounds.stop_count_max
      )
    end

    {:reply, :ok, %{server | state: state}}
  end

  defp apply_value(value, {state, counts}, %{table: table}) do
    case StopRecords.decode(value) do
      {:ok, fetch} ->
        case State.put(state, fetch) do
          {state, {:switched, %{held_stops: held_stops, removed_ids: removed_ids}}} ->
            true = :ets.insert(table, Enum.map(held_stops, &{&1.id, &1}))
            Enum.each(removed_ids, &:ets.delete(table, &1))
            changed = length(held_stops) + length(removed_ids)
            {state, %{counts | switched: counts.switched + 1, changed: counts.changed + changed}}

          {state, :ignored} ->
            {state, counts}

          {state, :refused} ->
            {state, %{counts | refused: counts.refused + 1}}
        end

      {:error, :unsupported_type} ->
        {state, counts}

      {:error, _reason} ->
        {state, %{counts | invalid: counts.invalid + 1}}
    end
  end

  defp announce(%{name: name, pubsub: pubsub}) do
    case Phoenix.PubSub.broadcast(pubsub, topic(name), {:stop_view_switched, name}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Stop view switch not announced",
          view: inspect(name),
          reason: inspect(reason)
        )
    end
  end

  defp topic(view), do: "stop_view:" <> Atom.to_string(view)
end
