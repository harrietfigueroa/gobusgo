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
  `fetch_times/1`, and `attempt_times/1` read its tables and never wait on
  the process. The
  table holds each identifier's current fetch as one entry, so a reader sees
  a whole fetch or the one before it.

  When the current fetch of at least one identifier changes or expires, the
  view announces it once per `apply_records/2` call to the processes that called
  `subscribe/1`, as `{:fetch_view_switched, view}`, after the table holds
  the new fetches.

  A record of another dataset is passed over and not counted. Any other
  value that is not a record is skipped. Each call logs `debug` when a
  current fetch changed or expired, `warning` with the count of skipped values, and
  `warning` when an announcement could not be sent.

  A view started with `:fetch_age_ms_max` drops a fetch once it is that
  old: each `apply_records/2` call first removes the fetches that have
  expired by the view's clock, and ignores a record of a fetch that old. A
  view that receives no records keeps what it holds, so a reader that needs
  a fresh fetch reads the fetch time.

  `note_attempt/2` tells the view that a fetch of an identifier was
  recorded, and `attempt_times/1` returns, for every identifier, the later
  of its fetch time and its attempt time. A recorded fetch that never
  reaches the view, because its response does not process, therefore still
  has a time, and a schedule that reads `attempt_times/1` waits as long
  after it as after a fetch the view holds. The attempts live in a second
  table, which readers read without waiting on the process.

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
  `options[:pubsub]`. `options[:fetch_age_ms_max]` makes its fetches expire,
  by the time `options[:clock]`, a zero-arity function, returns; the clock
  defaults to `DateTime.utc_now/0`.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options =
      Keyword.validate!(options, [
        :name,
        :pubsub,
        :records,
        :id_count_max,
        fetch_age_ms_max: nil,
        clock: &DateTime.utc_now/0
      ])

    clock = Keyword.fetch!(options, :clock)
    Assert.condition(is_function(clock, 0), "clock must be a zero-arity function")
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
      clock: clock,
      id_count_max: Keyword.fetch!(options, :id_count_max),
      fetch_age_ms_max: Keyword.fetch!(options, :fetch_age_ms_max)
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
  Returns the request identifier of the current fetch of `id` in `view`,
  reading no other field, or `nil` for an identifier that has none and
  while the view is not running.
  """
  @spec request_id(atom(), String.t()) :: String.t() | nil
  def request_id(view, id) when is_atom(view) and is_binary(id) do
    case :ets.whereis(view) do
      :undefined ->
        nil

      table ->
        case :ets.select(table, [{{id, %{request_id: :"$1"}}, [], [:"$1"]}]) do
          [request_id] -> request_id
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
  Returns the time of the latest fetch attempt of every identifier of `view`
  that has one: the fetch time of its current fetch, or the time of a later
  recorded fetch that has not reached the view. Returns `%{}` before a fetch
  or an attempt arrives and while the view is not running.
  """
  @spec attempt_times(atom()) :: %{String.t() => DateTime.t()}
  def attempt_times(view) when is_atom(view) do
    attempts =
      case :ets.whereis(attempt_table(view)) do
        :undefined -> %{}
        table -> table |> :ets.tab2list() |> Map.new()
      end

    Map.merge(fetch_times(view), attempts, fn _id, fetched_at, attempted_at ->
      Enum.max([fetched_at, attempted_at], DateTime)
    end)
  end

  @doc """
  Notes in `view` that a fetch of `attempt.id` made at `attempt.fetched_at`
  was recorded, and returns once `attempt_times/1` reflects it. Exits when
  the view does not answer within #{@call_timeout_ms} ms.
  """
  @spec note_attempt(atom(), %{id: String.t(), fetched_at: DateTime.t()}) :: :ok
  def note_attempt(view, %{id: id, fetched_at: %DateTime{}} = attempt)
      when is_atom(view) and is_binary(id) do
    GenServer.call(view, {:note_attempt, attempt}, @call_timeout_ms)
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
  def init(%{name: name} = server) do
    table = :ets.new(name, [:named_table, :protected, :set, read_concurrency: true])

    attempt_table =
      :ets.new(attempt_table(name), [:named_table, :protected, :set, read_concurrency: true])

    server =
      server
      |> Map.put(:table, table)
      |> Map.put(:attempt_table, attempt_table)
      |> Map.put(:state, new_state(server))

    {:ok, server}
  end

  defp new_state(%{fetch_age_ms_max: nil, id_count_max: id_count_max}),
    do: State.new(id_count_max)

  defp new_state(%{fetch_age_ms_max: fetch_age_ms_max, id_count_max: id_count_max}) do
    State.new_expiring(%{id_count_max: id_count_max, fetch_age_ms_max: fetch_age_ms_max})
  end

  @impl GenServer
  def handle_call({:note_attempt, attempt}, _from, server) do
    state = State.attempt(server.state, attempt)
    write_attempts(server, state)
    {:reply, :ok, %{server | state: state}}
  end

  def handle_call({:apply_records, values}, _from, %{table: table, name: name} = server) do
    {state, expired_ids} = State.expire(server.state, server.clock.())
    Enum.each(expired_ids, &:ets.delete(table, &1))
    counts = %{switched: %{}, invalid: 0}
    {state, counts} = Enum.reduce(values, {state, counts}, &apply_value(&1, &2, server))
    true = :ets.insert(table, Map.to_list(counts.switched))
    write_attempts(server, state)

    if map_size(counts.switched) >= 1 or expired_ids != [] do
      Logger.debug("Fetch view switched",
        view: inspect(name),
        id_count: map_size(counts.switched),
        expired_count: length(expired_ids)
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

  defp attempt_table(view), do: Module.concat(view, Attempts)

  # Brings the attempt table to the attempts of `state`. The entries that
  # stay are never absent in between, so a reader never takes an identifier
  # with an attempt for one without.
  defp write_attempts(%{attempt_table: attempt_table, state: state_before}, state) do
    attempts = State.attempts(state)
    attempts_before = State.attempts(state_before)

    if attempts != attempts_before do
      for {id, _attempted_at} <- attempts_before, not is_map_key(attempts, id) do
        true = :ets.delete(attempt_table, id)
      end

      true = :ets.insert(attempt_table, Map.to_list(attempts))
    end

    :ok
  end

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
