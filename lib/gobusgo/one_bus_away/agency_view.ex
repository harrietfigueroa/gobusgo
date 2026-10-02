defmodule Gobusgo.OneBusAway.AgencyView do
  @moduledoc """
  The agencies of the latest complete fetch, held in memory for readers.
  This module owns the process and the table; the rules that decide which
  fetch is current live in `Gobusgo.OneBusAway.AgencyView.State`.

  A view is a process registered under a name and a table of the same name.
  `apply_records/2` hands it record values, the bytes
  `Gobusgo.OneBusAway.AgencyBatch.Records` builds; `current/1` reads the
  table and never waits on the process. The table holds the current fetch as
  one entry, so a reader sees a whole fetch or the one before it.

  When the current fetch changes, the view announces it once to the
  processes that called `subscribe/1`, as `{:agency_view_switched, view}`,
  after the table holds the new fetch.

  A value that is not a record is skipped. Each call logs `info` when the
  current fetch changed and `warning` with the count of skipped values, and
  `warning` when an announcement could not be sent.

  A view starts empty. It holds nothing across a restart.
  """

  use GenServer

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.AgencyBatch.Records
  alias Gobusgo.OneBusAway.AgencyView.State
  alias Gobusgo.Publisher

  @call_timeout_ms 5_000
  @current_key :current

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
  server the view was started with. Each switch arrives as
  `{:agency_view_switched, view}`.
  """
  @spec subscribe(%{view: atom(), pubsub: atom()}) :: :ok
  def subscribe(%{view: view, pubsub: pubsub}) when is_atom(view) and is_atom(pubsub) do
    :ok = Phoenix.PubSub.subscribe(pubsub, topic(view))
  end

  @doc """
  Returns the current fetch of `view`: its `:request_id`, `:fetched_at`,
  `:agency_ids` in order, and `:agencies` by identifier. Returns `nil` before
  a fetch is complete and while the view is not running.
  """
  @spec current(atom()) :: State.current() | nil
  def current(view) when is_atom(view) do
    case :ets.whereis(view) do
      :undefined ->
        nil

      table ->
        case :ets.lookup(table, @current_key) do
          [{@current_key, current}] -> current
          [] -> nil
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
    {state, counts} = Enum.reduce(values, {state, %{switched: 0, invalid: 0}}, &apply_value/2)

    if counts.switched >= 1 do
      current = State.current(state)
      true = :ets.insert(table, {@current_key, current})

      Logger.info("Agency view switched",
        request_id: current.request_id,
        fetched_at: DateTime.to_iso8601(current.fetched_at, :extended),
        agency_count: length(current.agency_ids)
      )

      announce(server)
    end

    if counts.invalid >= 1 do
      Logger.warning("Agency view skipped invalid records", invalid_count: counts.invalid)
    end

    {:reply, :ok, %{server | state: state}}
  end

  defp announce(%{name: name, pubsub: pubsub}) do
    case Phoenix.PubSub.broadcast(pubsub, topic(name), {:agency_view_switched, name}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Agency view switch not announced", reason: inspect(reason))
    end
  end

  defp topic(view), do: "agency_view:" <> Atom.to_string(view)

  defp apply_value(value, {state, counts}) do
    case Records.decode(value) do
      {:ok, decoded} ->
        case State.put(state, decoded) do
          {state, :switched} -> {state, %{counts | switched: counts.switched + 1}}
          {state, _outcome} -> {state, counts}
        end

      {:error, _reason} ->
        {state, %{counts | invalid: counts.invalid + 1}}
    end
  end
end
