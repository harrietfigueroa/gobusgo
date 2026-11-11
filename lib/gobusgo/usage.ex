defmodule Gobusgo.Usage do
  @open_count_max_default 5_000
  @closed_count_max_default 5_000
  @write_interval_ms_default 60_000
  @register_timeout_ms 1_000
  @write_timeout_ms 10_000

  @moduledoc """
  The recorder of page connections: it holds each connection a page
  registers until the page's process exits, and stores the records of the
  connections that have ended through `Gobusgo.Writer`. This module owns the
  process, the monitors, the clocks, and the writes; the rules live in
  `Gobusgo.Usage.State` and the record in `Gobusgo.Usage.Records`.

  A page registers its connection with `register/2` and names the filter it
  shows with `put_filter/2`. The recorder monitors the page, so a page that
  exits, a crash included, ends its connection. `register/2` waits at most
  #{@register_timeout_ms} ms and returns `{:error, :unavailable}` for a
  recorder that is not running or does not answer, so a page never fails
  for its recorder.

  A request that has no connection to keep is recorded with `count/2`: the
  record of a connection that ended the moment it began, with a duration of
  0. It names no process and holds nothing open.

  Every #{@write_interval_ms_default} ms by default, and when it shuts down,
  the recorder writes the records it holds as one file, at most
  `Gobusgo.Usage.Records.file_record_count_max/0` of them, and nothing when
  it holds none. It logs `Usage records written` at `info` with the count
  written and the counts its bounds dropped since the last file. A write
  that fails keeps its records for the next write and is logged as
  `Usage records not written` at `error`.

  By default the recorder holds at most #{@open_count_max_default} open
  connections and #{@closed_count_max_default} records. State is in memory
  and per node: a restart loses the open connections and the records not
  yet written.

  Registering logs nothing: a connection's facts are one visitor's.
  """

  use GenServer

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.RequestId
  alias Gobusgo.Usage.Records
  alias Gobusgo.Usage.State
  alias Gobusgo.Writer

  @type register_error :: :open_count_exceeded | :unavailable

  @type write_result :: {:ok, non_neg_integer()} | {:error, Writer.error_reason()}

  @doc """
  Starts a recorder. `:name` registers it and is required. `:write_options`
  are the options of `Gobusgo.Writer.write/2`. `:open_count_max`,
  `:closed_count_max`, and `:write_interval_ms` replace the defaults above.
  `:clock` returns the time in UTC, `:monotonic_time_ms` the time in
  milliseconds on a clock that never goes back, and `:file_id` a name no
  other file has; each is a zero-arity function.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options =
      Keyword.validate!(options, [
        :name,
        write_options: [],
        open_count_max: @open_count_max_default,
        closed_count_max: @closed_count_max_default,
        write_interval_ms: @write_interval_ms_default,
        clock: &DateTime.utc_now/0,
        monotonic_time_ms: &monotonic_time_ms_default/0,
        file_id: &RequestId.generate/0
      ])

    name = Keyword.fetch!(options, :name)
    Assert.condition(is_atom(name), "name must be an atom, got: #{inspect(name)}")

    for key <- [:clock, :monotonic_time_ms, :file_id] do
      Assert.condition(
        is_function(Keyword.fetch!(options, key), 0),
        "#{key} must be a zero-arity function"
      )
    end

    write_interval_ms = Keyword.fetch!(options, :write_interval_ms)
    Assert.condition(is_integer(write_interval_ms), "write_interval_ms must be an integer")
    Assert.condition(write_interval_ms >= 1, "write_interval_ms must be positive")

    GenServer.start_link(__MODULE__, Map.new(options), name: name)
  end

  @doc """
  Registers the connection of the calling process, until the process exits.
  Registering again while the connection is open is `:ok` and keeps it.
  """
  @spec register(GenServer.server(), Records.connection()) :: :ok | {:error, register_error()}
  def register(recorder, %{page: page} = connection) when is_binary(page) do
    GenServer.call(recorder, {:register, connection}, @register_timeout_ms)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc """
  Records one request as a connection that ended as it began, so each request
  of one process is one record where `register/2` keeps one connection per
  process. It is refused as `register/2` is, for a recorder at its bound or
  one that is not running.
  """
  @spec count(GenServer.server(), Records.connection()) :: :ok | {:error, register_error()}
  def count(recorder, %{page: page} = connection) when is_binary(page) do
    GenServer.call(recorder, {:count, connection}, @register_timeout_ms)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc """
  Names the filter the calling process's connection shows now. It changes
  nothing for a process with no open connection or a recorder that is not
  running.
  """
  @spec put_filter(GenServer.server(), Records.filter()) :: :ok
  def put_filter(recorder, filter) when is_map(filter) do
    GenServer.cast(recorder, {:put_filter, self(), filter})
  end

  @doc """
  Writes the records the recorder holds now, as the timer does, and returns
  how many it wrote or why the writer stored none.
  """
  @spec write(GenServer.server()) :: write_result()
  def write(recorder), do: GenServer.call(recorder, :write, @write_timeout_ms)

  @impl GenServer
  def init(options) do
    # The recorder writes what it holds in terminate/2, which a shutdown
    # reaches only in a process that traps exits.
    Process.flag(:trap_exit, true)

    state =
      State.new(%{
        open_count_max: options.open_count_max,
        closed_count_max: options.closed_count_max
      })

    recorder = %{
      state: state,
      monitors: %{},
      write_options: options.write_options,
      write_interval_ms: options.write_interval_ms,
      clock: options.clock,
      monotonic_time_ms: options.monotonic_time_ms,
      file_id: options.file_id
    }

    {:ok, schedule_write(recorder)}
  end

  @impl GenServer
  def handle_call({:register, connection}, {pid, _tag}, recorder) do
    opening = %{
      holder: pid,
      connection: connection,
      connected_at: now(recorder),
      now_ms: now_ms(recorder)
    }

    case State.open(recorder.state, opening) do
      {state, :opened} ->
        {:reply, :ok, monitor(%{recorder | state: state}, pid)}

      {_state, :already_open} ->
        {:reply, :ok, recorder}

      {state, :open_count_exceeded = refusal} ->
        {:reply, {:error, refusal}, %{recorder | state: state}}
    end
  end

  def handle_call({:count, connection}, _from, recorder) do
    holder = make_ref()
    now_ms = now_ms(recorder)

    opening = %{
      holder: holder,
      connection: connection,
      connected_at: now(recorder),
      now_ms: now_ms
    }

    case State.open(recorder.state, opening) do
      {state, :opened} ->
        state = State.close(state, %{holder: holder, now_ms: now_ms})
        {:reply, :ok, %{recorder | state: state}}

      {state, :open_count_exceeded = refusal} ->
        {:reply, {:error, refusal}, %{recorder | state: state}}
    end
  end

  def handle_call(:write, _from, recorder) do
    {result, recorder} = write_closed(recorder)
    {:reply, result, recorder}
  end

  @impl GenServer
  def handle_cast({:put_filter, pid, filter}, recorder) do
    state = State.put_filter(recorder.state, %{holder: pid, filter: filter})
    {:noreply, %{recorder | state: state}}
  end

  @impl GenServer
  def handle_info({:DOWN, reference, :process, pid, _reason}, recorder) do
    case Map.pop(recorder.monitors, pid) do
      {^reference, monitors} ->
        state = State.close(recorder.state, %{holder: pid, now_ms: now_ms(recorder)})
        {:noreply, %{recorder | state: state, monitors: monitors}}

      {_other, _monitors} ->
        {:noreply, recorder}
    end
  end

  def handle_info(:write, recorder) do
    {_result, recorder} = write_closed(recorder)
    {:noreply, schedule_write(recorder)}
  end

  # The exit of a process the recorder is linked to, which it sees as a
  # message because it traps exits.
  def handle_info({:EXIT, _pid, _reason}, recorder), do: {:noreply, recorder}

  @impl GenServer
  def terminate(_reason, recorder) do
    {_result, _recorder} = write_closed(recorder)
    :ok
  end

  defp write_closed(%{state: state} = recorder) do
    case State.closed(state, Records.file_record_count_max()) do
      [] ->
        {{:ok, 0}, recorder}

      records ->
        file =
          Records.file(%{records: records, written_at: now(recorder), file_id: file_id(recorder)})

        record_count = length(records)

        case Writer.write(file, recorder.write_options) do
          :ok ->
            {dropped, state} = state |> State.drop_closed(record_count) |> State.take_dropped()

            Logger.info("Usage records written",
              record_count: record_count,
              dropped_open_count: dropped.open_count,
              dropped_closed_count: dropped.closed_count
            )

            {{:ok, record_count}, %{recorder | state: state}}

          {:error, reason} ->
            Logger.error("Usage records not written",
              record_count: record_count,
              reason: inspect(reason)
            )

            {{:error, reason}, recorder}
        end
    end
  end

  defp schedule_write(%{write_interval_ms: write_interval_ms} = recorder) do
    Process.send_after(self(), :write, write_interval_ms)
    recorder
  end

  defp monitor(%{monitors: monitors} = recorder, pid) do
    %{recorder | monitors: Map.put(monitors, pid, Process.monitor(pid))}
  end

  defp now(%{clock: clock}) do
    now = clock.()

    Assert.condition(
      match?(%DateTime{time_zone: "Etc/UTC"}, now),
      "the clock must return a UTC time"
    )

    now
  end

  defp now_ms(%{monotonic_time_ms: monotonic_time_ms}) do
    now_ms = monotonic_time_ms.()
    Assert.condition(is_integer(now_ms), "the monotonic clock must return an integer")
    now_ms
  end

  defp file_id(%{file_id: file_id}) do
    id = file_id.()
    Assert.condition(is_binary(id), "file_id must return a string")
    id
  end

  defp monotonic_time_ms_default, do: System.monotonic_time(:millisecond)
end
