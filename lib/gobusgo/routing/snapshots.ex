defmodule Gobusgo.Routing.Snapshots do
  # The measuring's own deadline is checked between tiles and a read has up to
  # a minute, so the kill waits for the read.
  @deadline_grace_ms 70_000
  @check_interval_ms 600_000
  @run_deadline_ms 120_000
  @format_version Gobusgo.Routing.SnapshotFormat.version()

  @moduledoc """
  The process that holds the manifest of the published routing snapshots,
  one per service date the schedule view holds.

  A build writes a snapshot's files through `Gobusgo.Writer` and then hands
  its manifest entry here with `record/2`, so the manifest names only files
  already stored. The process also holds, per service date, the SHA-256 of
  the inputs the entry was built from and the UTC date it was built on, so
  a build passes over a date whose inputs are unchanged since a build of
  the same day. A build on a later day writes the files again under that
  day, which keeps every file the manifest names inside its retention.

  A date whose trip path build failed is recorded without its trip paths
  and with the state of `Gobusgo.Routing.TripPathRetry`, which the build
  reads to build only the trip paths again once the backoff has passed.

  The manifest is what this node built: it starts empty on every start, and
  the first build after a start builds every date, trip paths included, so
  a start retries a failed trip path build at once.

  The process also holds the table of walking links measured along the walk
  graph (`Gobusgo.Routing.WalkLinks`) as one packed binary, which it keeps off
  its heap and hands to a date's build without a copy. `walk_links/2` asks for
  the table for the positions now held: it answers at once, and a table that
  is not current is measured in a process of its own, linked, under a heap cap
  and a deadline, so a request never waits for it. A graph build whose
  files are corrupt is not read again, nor are positions whose measuring
  process was killed; a read that failed or a deadline is asked again by the
  next request.

  `spec/1` is the spec of the scheduler that checks every
  #{@check_interval_ms} ms whether to build, with #{@run_deadline_ms} ms for
  a run.
  """

  use GenServer

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Routing.WalkLinks
  alias Gobusgo.Routing.WalkLinks.Store
  alias Gobusgo.Routing.Snapshots.Build
  alias Gobusgo.Scheduler

  @type server :: GenServer.server()

  @type built :: %{
          inputs_sha256: binary(),
          built_on: Date.t(),
          entry: map(),
          trip_path_failure: :none | Gobusgo.Routing.TripPathRetry.state()
        }

  @doc "Starts the process. `:name` registers it."
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options = Keyword.validate!(options, [:name])
    name = Keyword.fetch!(options, :name)
    Assert.condition(is_atom(name), "name must be an atom, got: #{inspect(name)}")
    GenServer.start_link(__MODULE__, :ok, name: name)
  end

  @doc """
  The manifest: the format version and the entry of every snapshot, in
  service date order.
  """
  @spec manifest(server()) :: %{String.t() => term()}
  def manifest(server) do
    entries = GenServer.call(server, :entries)

    %{
      "formatVersion" => @format_version,
      "snapshots" =>
        entries
        |> Enum.sort_by(fn {date, _entry} -> date end, Date)
        |> Enum.map(&elem(&1, 1).entry)
    }
  end

  @doc """
  What each service date's current snapshot was built from and on, its
  entry, and the state of its failed trip path builds, `:none` where the
  last one succeeded or none was made.
  """
  @spec built(server()) :: %{Date.t() => built()}
  def built(server) do
    server
    |> GenServer.call(:entries)
    |> Map.new(fn {date, entry} ->
      {date,
       Map.take(entry, [:inputs_sha256, :other_sha256, :built_on, :entry, :trip_path_failure])}
    end)
  end

  @doc """
  Makes `snapshot.entry` the manifest entry of `snapshot.service_date`,
  built on `snapshot.built_on` from inputs whose SHA-256 is
  `snapshot.inputs_sha256`, with `snapshot.trip_path_failure`, the state of
  its failed trip path builds or `:none`. A later `record/2` of the date
  replaces all of it, so the failure state ends with the inputs it is of.
  """
  @spec record(server(), %{
          service_date: Date.t(),
          entry: map(),
          inputs_sha256: binary(),
          built_on: Date.t(),
          trip_path_failure: :none | Gobusgo.Routing.TripPathRetry.state()
        }) :: :ok
  def record(
        server,
        %{
          service_date: %Date{},
          entry: entry,
          inputs_sha256: sha256,
          built_on: %Date{},
          trip_path_failure: failure
        } = snapshot
      )
      when is_map(entry) and byte_size(sha256) == 32 and (failure == :none or is_map(failure)) do
    GenServer.call(server, {:record, snapshot})
  end

  @doc "Drops the entry of every service date outside `service_dates`."
  @spec retain(server(), [Date.t()]) :: :ok
  def retain(server, service_dates) when is_list(service_dates) do
    GenServer.call(server, {:retain, service_dates})
  end

  @doc "The milliseconds between two runs of the build."
  @spec check_interval_ms() :: pos_integer()
  def check_interval_ms, do: @check_interval_ms

  @doc "The milliseconds a run of the build has."
  @spec run_deadline_ms() :: pos_integer()
  def run_deadline_ms, do: @run_deadline_ms

  @doc "The milliseconds past a measuring's deadline that it is left running before it is killed."
  @spec deadline_grace_ms() :: pos_integer()
  def deadline_grace_ms, do: @deadline_grace_ms

  @doc """
  The spec of the scheduler that builds the snapshots of `options[:server]`.
  The other options go to `Gobusgo.Routing.Snapshots.Build.run/1`. The spec
  passes `Gobusgo.Scheduler.assert_spec/1`.
  """
  @spec spec(Keyword.t()) :: Scheduler.spec()
  def spec(options) when is_list(options) do
    spec = %{
      name: Gobusgo.Routing.SnapshotScheduler,
      run: fn -> Build.run(options) end,
      cadence: %{policy: {:fixed, @check_interval_ms}, signals: &no_signals/0},
      deadline_ms: @run_deadline_ms
    }

    Scheduler.assert_spec(spec)
    spec
  end

  defp no_signals, do: %{}

  @typedoc """
  What `walk_links/2` is asked: the `manifest` of the graph build to measure
  over (`Gobusgo.Routing.WalkLinks.Store.manifest/1`), the `positions` of the
  stops, the reader's `read_options`, the heap cap of the measuring process in
  words, how many milliseconds it has, and the milliseconds past that before it
  is killed.
  """
  @type walk_links_request :: %{
          manifest: Store.manifest(),
          positions: WalkLinks.positions(),
          read_options: keyword(),
          heap_words_max: pos_integer(),
          deadline_ms: pos_integer(),
          deadline_grace_ms: non_neg_integer(),
          start?: boolean()
        }

  @doc """
  The table of walking links for `request.positions` on the graph build
  `request.manifest` names: `{:ready, %{table: binary, build_id: build_id}}`
  when it is held, `:pending` while it is being measured, `:not_current` for
  a request that only asks (`start?: false`) when the table is not current and
  nothing is measuring it, or `{:failed, reason}` for a build whose files are
  corrupt or positions whose process was killed or crashed.
  """
  @spec walk_links(server(), walk_links_request()) ::
          {:ready, %{table: binary(), build_id: String.t()}}
          | :pending
          | :not_current
          | {:failed, :corrupt | :killed}
  def walk_links(server, %{manifest: %{build_id: _}, positions: %{}} = request) do
    GenServer.call(server, {:walk_links, request})
  end

  @doc """
  The last table of walking links this process measured, `%{table: binary,
  build_id: build_id}`, or `nil` before the first: what a build stands on while
  the table for the positions now held is not current.
  """
  @spec walk_table(server()) :: %{table: binary(), build_id: String.t()} | nil
  def walk_table(server), do: GenServer.call(server, :walk_table)

  @impl GenServer
  def init(:ok) do
    Process.flag(:trap_exit, true)

    walk = %{
      table: nil,
      build_id: nil,
      key: nil,
      task: nil,
      corrupt: MapSet.new(),
      killed: MapSet.new()
    }

    {:ok, %{entries: %{}, walk: walk}}
  end

  @impl GenServer
  def handle_call(:entries, _from, %{entries: entries} = state), do: {:reply, entries, state}

  def handle_call(:walk_table, _from, %{walk: %{table: table, build_id: build_id}} = state) do
    held = if is_binary(table), do: %{table: table, build_id: build_id}
    {:reply, held, state}
  end

  def handle_call({:record, %{service_date: date} = snapshot}, _from, %{entries: entries} = state) do
    entries = Map.put(entries, date, Map.delete(snapshot, :service_date))
    {:reply, :ok, %{state | entries: entries}}
  end

  def handle_call({:retain, service_dates}, _from, %{entries: entries} = state) do
    {:reply, :ok, %{state | entries: Map.take(entries, service_dates)}}
  end

  def handle_call({:walk_links, request}, _from, %{walk: walk} = state) do
    build_id = request.manifest.build_id
    key = WalkLinks.key(%{build_id: build_id, positions: request.positions})
    {answer, walk} = walk_answer({build_id, key}, request, walk)
    {:reply, answer, %{state | walk: walk}}
  end

  @impl GenServer
  def handle_info({:walk_links, ref, result}, %{walk: %{task: %{ref: ref}} = walk} = state) do
    {:noreply, %{state | walk: finish_walk_links(result, walk)}}
  end

  def handle_info({:walk_links, _stale_ref, _result}, state), do: {:noreply, state}

  def handle_info(
        {:walk_links_deadline, ref},
        %{walk: %{task: %{ref: ref, pid: pid} = task} = walk} = state
      ) do
    Process.exit(pid, :kill)
    {:noreply, %{state | walk: %{walk | task: Map.put(task, :deadline_fired?, true)}}}
  end

  def handle_info({:walk_links_deadline, _stale_ref}, state), do: {:noreply, state}

  def handle_info({:EXIT, pid, reason}, %{walk: %{task: %{pid: pid}} = walk} = state) do
    {:noreply, %{state | walk: lost_walk_links(reason, walk)}}
  end

  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # ---- The walking links.

  defp walk_answer({build_id, key}, request, walk) do
    cond do
      MapSet.member?(walk.corrupt, build_id) ->
        {{:failed, :corrupt}, walk}

      walk.key == key and is_binary(walk.table) ->
        {{:ready, %{table: walk.table, build_id: build_id}}, walk}

      walk.task != nil ->
        {:pending, walk}

      MapSet.member?(walk.killed, key) ->
        {{:failed, :killed}, walk}

      true ->
        start_or_wait({build_id, key}, request, walk)
    end
  end

  # The table is measured in a process of its own, with a full sweep at every
  # collection and a heap cap, linked so it dies with this process; this
  # process traps exits, so the kill of the measuring reaches it as a message.
  # A request that only asks leaves a table that is not current unmeasured, so a
  # requester can ask first and start the measuring later, when the memory of
  # its own work is freed.
  defp start_or_wait({build_id, key}, request, walk) do
    if Map.get(request, :start?, true) do
      {:pending, start_walk_links({build_id, key}, request, walk)}
    else
      {:not_current, walk}
    end
  end

  defp start_walk_links({build_id, key}, request, walk) do
    parent = self()
    ref = make_ref()
    previous = previous_table(walk, build_id)
    started_ms = System.monotonic_time(:millisecond)

    pid =
      :erlang.spawn_opt(
        fn -> send(parent, {:walk_links, ref, measure(request, previous, started_ms)}) end,
        [
          :link,
          fullsweep_after: 0,
          max_heap_size: %{size: request.heap_words_max, kill: true, error_logger: false}
        ]
      )

    Process.send_after(
      self(),
      {:walk_links_deadline, ref},
      request.deadline_ms + request.deadline_grace_ms
    )

    task = %{
      ref: ref,
      pid: pid,
      key: key,
      build_id: build_id,
      heap_words_max: request.heap_words_max,
      started_ms: started_ms
    }

    %{walk | task: task}
  end

  defp previous_table(%{build_id: build_id, table: table}, build_id) when is_binary(table),
    do: table

  defp previous_table(_walk, _build_id), do: nil

  defp measure(request, previous_binary, started_ms) do
    build_id = request.manifest.build_id
    positions = request.positions
    previous = unpacked(previous_binary)

    with {:ok, index} <- Store.index(request.manifest, request.read_options),
         {:ok, %{table: table, stats: stats}} <-
           WalkLinks.compute(%{
             positions: positions,
             stop_ids:
               WalkLinks.stale_stop_ids(%{
                 positions: positions,
                 table: previous,
                 build_id: build_id
               }),
             previous: previous,
             build_id: build_id,
             index: index,
             load_shard: Store.loader(build_id, request.read_options),
             deadline_ms: started_ms + request.deadline_ms
           }) do
      {:ok, %{table: WalkLinks.pack(table), stats: stats}}
    else
      {:error, :corrupt} -> {:error, :corrupt, :index}
      {:error, {:io, reason}} -> {:error, :io, {:index, reason}}
      {:error, _kind, _detail} = failure -> failure
    end
  end

  defp unpacked(nil), do: nil
  defp unpacked(binary), do: WalkLinks.unpack(binary)

  defp finish_walk_links({:ok, %{table: table, stats: stats}}, %{task: task} = walk) do
    elapsed_ms = System.monotonic_time(:millisecond) - task.started_ms

    Logger.info(
      "Routing walk links built",
      Keyword.new(Map.put(stats, :elapsed_ms, elapsed_ms)) ++ [build_id: task.build_id]
    )

    %{walk | table: table, build_id: task.build_id, key: task.key, task: nil}
  end

  defp finish_walk_links({:error, :corrupt, detail}, %{task: task} = walk) do
    Logger.error(
      "Routing walk graph corrupt",
      [build_id: task.build_id] ++ detail_properties(detail)
    )

    %{walk | task: nil, corrupt: MapSet.put(walk.corrupt, task.build_id)}
  end

  defp finish_walk_links({:error, :killed, _detail}, walk), do: lost_walk_links(:killed, walk)

  defp finish_walk_links({:error, :crashed, {_tile, reason}}, walk) do
    lost_walk_links(reason, walk)
  end

  defp finish_walk_links({:error, cause, detail}, %{task: task} = walk)
       when cause in [:io, :deadline] do
    Logger.warning(
      "Routing walk links not built",
      [cause: cause, build_id: task.build_id] ++ detail_properties(detail)
    )

    %{walk | task: nil}
  end

  defp lost_walk_links(:normal, walk), do: walk

  # The kill that follows the deadline is the deadline's, and is asked again; a
  # kill of the heap cap and a crash of the process are not, for the same
  # positions.
  defp lost_walk_links(:killed, %{task: %{deadline_fired?: true} = task} = walk) do
    Logger.warning("Routing walk links not built", cause: :deadline, build_id: task.build_id)
    %{walk | task: nil}
  end

  defp lost_walk_links(:killed, %{task: task} = walk) do
    Logger.error("Routing walk links build killed",
      build_id: task.build_id,
      heap_words_max: task.heap_words_max
    )

    %{walk | task: nil, killed: MapSet.put(walk.killed, task.key)}
  end

  defp lost_walk_links(reason, %{task: task} = walk) do
    Logger.error("Routing walk links build crashed",
      build_id: task.build_id,
      reason: inspect(reason)
    )

    %{walk | task: nil, killed: MapSet.put(walk.killed, task.key)}
  end

  defp detail_properties({row, column}) when is_integer(row) and is_integer(column) do
    [tile_row: row, tile_column: column]
  end

  defp detail_properties({{row, column}, reason}) do
    detail_properties({row, column}) ++ [reason: inspect(reason)]
  end

  defp detail_properties({source, reason}) when is_atom(source) do
    [source: source, reason: inspect(reason)]
  end

  defp detail_properties(detail) when is_atom(detail), do: [source: detail]
end
