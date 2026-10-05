defmodule Gobusgo.OneBusAway.FetchView do
  @moduledoc """
  The latest fetch of each identifier of one dataset, held in memory for
  readers. This module owns the process and the table; the rules that decide
  which fetch is current live in `Gobusgo.OneBusAway.FetchView.State`.

  A view serves a dataset whose every fetch is whole in one record. Its
  `:records` module has `decode/1`, which returns `{:ok, fetch}` for a
  record value of the dataset, the fetch holding its `:id`, `:request_id`,
  and `:fetched_at` beside the dataset's own fields, and
  `{:error, :unsupported_type}` for a record of another dataset on the same
  topic.

  A view is a process registered under a name and a table of the same name.
  `apply_records/2` hands it record values; `current/1`, `current_fetch/2`,
  and `fetch_times/1` read the table and never wait on the process. The
  table holds each identifier's current fetch as one entry, so a reader sees
  a whole fetch or the one before it.

  When the current fetch of at least one identifier changes, the view
  announces it once per `apply_records/2` call to the processes that called
  `subscribe/1`, as `{:fetch_view_switched, view}`, after the table holds
  the new fetches.

  A record of another dataset is passed over and not counted. Any other
  value that is not a record is skipped. Each call logs `debug` when a
  current fetch changed, `warning` with the count of skipped values, and
  `warning` when an announcement could not be sent.

  A view starts empty. It holds nothing across a restart.
  """

  use GenServer

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.FetchView.State
  alias Gobusgo.Publisher

  @call_timeout_ms 5_000

  @doc """
  Starts a view registered under `options[:name]` for the dataset of
  `options[:records]`, holding at most `options[:id_count_max]` identifiers,
  that announces its switches on the publish-subscribe server
  `options[:pubsub]`.
  """
  @spec start_link(name: atom(), pubsub: atom(), records: module(), id_count_max: pos_integer()) ::
          GenServer.on_start()
  def start_link(options) when is_list(options) do
    options = Keyword.validate!(options, [:name, :pubsub, :records, :id_count_max])
    name = Keyword.fetch!(options, :name)
    pubsub = Keyword.fetch!(options, :pubsub)
    records = Keyword.fetch!(options, :records)
    Assert.condition(is_atom(name), "name must be an atom, got: #{inspect(name)}")
    Assert.condition(is_atom(pubsub), "pubsub must be an atom, got: #{inspect(pubsub)}")
    Assert.condition(is_atom(records), "records must be a module, got: #{inspect(records)}")

    server = %{
      name: name,
      pubsub: pubsub,
      records: records,
      id_count_max: Keyword.fetch!(options, :id_count_max)
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
  switches an identifier arrives as one `{:fetch_view_switched, view}`.
  """
  @spec subscribe(%{view: atom(), pubsub: atom()}) :: :ok
  def subscribe(%{view: view, pubsub: pubsub}) when is_atom(view) and is_atom(pubsub) do
    :ok = Phoenix.PubSub.subscribe(pubsub, topic(view))
  end

  @doc """
  Returns the current fetch of every identifier of `view` that has one, in
  identifier order, each as its dataset's `decode/1` returns it. Returns
  `[]` before a fetch arrives and while the view is not running.
  """
  @spec current(atom()) :: [State.fetch()]
  def current(view) when is_atom(view) do
    case :ets.whereis(view) do
      :undefined ->
        []

      table ->
        table
        |> :ets.tab2list()
        |> Enum.sort_by(fn {id, _fetch} -> id end)
        |> Enum.map(fn {_id, fetch} -> fetch end)
    end
  end

  @doc """
  Returns the current fetch of `id` in `view`, or `nil` for an identifier
  that has none and while the view is not running.
  """
  @spec current_fetch(atom(), String.t()) :: State.fetch() | nil
  def current_fetch(view, id) when is_atom(view) and is_binary(id) do
    case :ets.whereis(view) do
      :undefined ->
        nil

      table ->
        case :ets.lookup(table, id) do
          [{^id, fetch}] -> fetch
          [] -> nil
        end
    end
  end

  @doc """
  Returns the fetch time of the current fetch of every identifier of `view`
  that has one, by identifier. It reads no other field, so it costs the same
  however much the fetches hold. Returns `%{}` before a fetch arrives and
  while the view is not running.
  """
  @spec fetch_times(atom()) :: %{String.t() => DateTime.t()}
  def fetch_times(view) when is_atom(view) do
    case :ets.whereis(view) do
      :undefined ->
        %{}

      table ->
        table
        |> :ets.select([{{:"$1", %{fetched_at: :"$2"}}, [], [{{:"$1", :"$2"}}]}])
        |> Map.new()
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

  @doc """
  Applies `values` to each of `views` in turn, as `apply_records/2` does:
  the form a topic that several datasets share hands its records over in.
  """
  @spec apply_records_to_each([atom()], [binary()]) :: :ok
  def apply_records_to_each(views, values) when is_list(views) and is_list(values) do
    Enum.each(views, &apply_records(&1, values))
  end

  @impl GenServer
  def init(%{name: name, id_count_max: id_count_max} = server) do
    table = :ets.new(name, [:named_table, :protected, :set, read_concurrency: true])
    {:ok, server |> Map.put(:table, table) |> Map.put(:state, State.new(id_count_max))}
  end

  @impl GenServer
  def handle_call({:apply_records, values}, _from, %{table: table, name: name} = server) do
    counts = %{switched: %{}, invalid: 0}
    {state, counts} = Enum.reduce(values, {server.state, counts}, &apply_value(&1, &2, server))

    if map_size(counts.switched) >= 1 do
      true = :ets.insert(table, Map.to_list(counts.switched))

      Logger.debug("Fetch view switched",
        view: inspect(name),
        id_count: map_size(counts.switched)
      )

      announce(server)
    end

    if counts.invalid >= 1 do
      Logger.warning("Fetch view skipped invalid records",
        view: inspect(name),
        invalid_count: counts.invalid
      )
    end

    {:reply, :ok, %{server | state: state}}
  end

  defp announce(%{name: name, pubsub: pubsub}) do
    case Phoenix.PubSub.broadcast(pubsub, topic(name), {:fetch_view_switched, name}) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("Fetch view switch not announced",
          view: inspect(name),
          reason: inspect(reason)
        )
    end
  end

  defp topic(view), do: "fetch_view:" <> Atom.to_string(view)

  defp apply_value(value, {state, counts}, %{records: records}) do
    case records.decode(value) do
      {:ok, %{id: id} = fetch} ->
        case State.put(state, fetch) do
          {state, :switched} -> {state, %{counts | switched: Map.put(counts.switched, id, fetch)}}
          {state, :ignored} -> {state, counts}
        end

      {:error, :unsupported_type} ->
        {state, counts}

      {:error, _reason} ->
        {state, %{counts | invalid: counts.invalid + 1}}
    end
  end
end
