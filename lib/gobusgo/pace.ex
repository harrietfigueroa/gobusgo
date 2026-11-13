defmodule Gobusgo.Pace do
  @check_interval_ms_default 60_000
  @vehicle_count_max_default Gobusgo.Pace.Observation.vehicle_count_max_default()
  @path_count_max_default Gobusgo.Pace.Observation.path_count_max_default()
  @path_build_count_max_default 200
  @message_queue_length_max_default 30

  @moduledoc """
  The pace table of the node: it learns, from the vehicle reports of each
  fetch, how long vehicles take at each place, and stores one day's table
  through `Gobusgo.Writer` once the UTC day is over. This module owns the
  process, the clock, and the write; the rules live in
  `Gobusgo.Pace.Learning` and the step of one fetch in
  `Gobusgo.Pace.Observation`, the cells in `Gobusgo.Pace.Table`, the stored
  form in `Gobusgo.Pace.Aggregate`, and the reading of a trip's path in
  `Gobusgo.Pace.PathSource`.

  `observe/2` casts the reports of a fetch and returns at once, and returns
  `:ok` for a process that is not running, so learning never slows or fails
  ingestion. Everything is bounded:

    * the table holds at most `:cell_count_max` cells
      (`Gobusgo.Pace.Table`); at the bound the process logs `Pace table full`
      at `warning` once for the day's table and drops the cells it does not
      hold;
    * the process remembers the last report of at most
      `:vehicle_count_max` vehicles, #{@vehicle_count_max_default} by default,
      and forgets one that a later report finds more than the pair bound
      old, and all of them at the bound;
    * it holds at most `:path_count_max` trip paths,
      #{@path_count_max_default} by default, and drops all of them at the
      bound, to read again as the trips are reported;
    * it reads at most `:path_build_count_max` paths from the views in one
      call to `observe/2`, #{@path_build_count_max_default} by default, and a
      report whose path is not held and not read places its vehicle nowhere.

    * `observe/2` skips a call, and counts the skip, while the process's
      message queue holds more than `:message_queue_length_max` messages,
      #{@message_queue_length_max_default} by default.

  Reports go to the table of the UTC date they are observed on. When the
  date is later than the table's, at an observation or at a check, the
  process writes the finished table and starts the next day's empty. A write
  that fails logs `Pace table not written` at `error` and sets the finished
  table aside as the pending table, which only the check, every
  #{@check_interval_ms_default} ms by default, writes again. The process
  holds one pending table: a finished table that fails to write while one is
  pending replaces it, and the replaced table's date, cells, and meters are
  logged at `error` as `Pace pending table dropped`. The process also writes
  both tables when it shuts down, so a restart keeps what it learned; each
  file is its own destination, and a reader sums the files of a date. A
  table with no cell is not written. `write/1` flushes: after a successful
  write the table of that date starts empty.

  The file's form is `Gobusgo.Pace.Aggregate`. A write logs `Pace table
  written` at `info` with the date, the count of cells, the meters, and the
  cells the bound left out, and the count of observations skipped since the
  last write. A path read that raises is logged once per call
  as `Pace paths not read` at `warning`, and the report is dropped.
  """

  use GenServer

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Pace.Aggregate
  alias Gobusgo.Pace.Learning
  alias Gobusgo.Pace.Observation
  alias Gobusgo.Pace.PathSource
  alias Gobusgo.Pace.Table
  alias Gobusgo.RequestId
  alias Gobusgo.Writer

  @doc """
  Hands the reports of the vehicles of one fetch to the process. The fetch is
  `fetch.agency_id` and `fetch.vehicles`, as
  `Gobusgo.OneBusAway.RawVehicleResponse.parse/1` returns them.
  """
  @spec observe(GenServer.server(), %{agency_id: String.t(), vehicles: [map()]}) :: :ok
  def observe(server, %{agency_id: agency_id, vehicles: vehicles})
      when is_binary(agency_id) and is_list(vehicles) do
    case GenServer.whereis(server) do
      nil ->
        :ok

      pid ->
        observe_pid(pid, server, %{agency_id: agency_id, vehicles: vehicles})
    end
  end

  defp observe_pid(pid, server, fetch) do
    {:message_queue_len, queue_length} = Process.info(pid, :message_queue_len)
    skip = :persistent_term.get({__MODULE__, server}, nil)

    case skip do
      %{counter: counter, queue_length_max: queue_length_max}
      when queue_length > queue_length_max ->
        :counters.add(counter, 1, 1)

      _no_skip ->
        reports = Learning.reports(fetch)
        GenServer.cast(pid, {:observe, reports})
    end
  end

  @doc """
  Flushes the table: writes it now and returns how many cells it wrote, and
  the process starts an empty table of the same date, so a reader
  that sums a date's files counts each cell once. A write that fails returns
  why the writer stored none and keeps the table.
  """
  @spec write(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, Writer.error_reason()}
  def write(server), do: GenServer.call(server, :write)

  @doc """
  Starts the process. `:name` registers it and is required. `:write_options`
  are the options of `Gobusgo.Writer.write/2`, `:views` the three views
  `Gobusgo.Pace.PathSource` reads, `:path_source` the function that reads a
  path, `:node` the node's name in a file's destination, `:clock` a function
  that returns the time in UTC, and `:file_id` one that returns a name no
  other file has. `:cell_count_max`, `:vehicle_count_max`,
  `:path_count_max`, `:path_build_count_max`, `:message_queue_length_max`,
  and `:check_interval_ms`
  replace the defaults.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(options) when is_list(options) do
    options =
      Keyword.validate!(options, [
        :name,
        write_options: [],
        views: %{
          schedule_view: Gobusgo.OneBusAway.RouteScheduleView,
          route_path_view: Gobusgo.OneBusAway.RoutePathView,
          stop_view: Gobusgo.OneBusAway.StopView
        },
        path_source: &PathSource.fetch/2,
        node: Atom.to_string(Node.self()),
        clock: &DateTime.utc_now/0,
        file_id: &RequestId.generate/0,
        cell_count_max: Table.cell_count_max_default(),
        vehicle_count_max: @vehicle_count_max_default,
        path_count_max: @path_count_max_default,
        path_build_count_max: @path_build_count_max_default,
        message_queue_length_max: @message_queue_length_max_default,
        check_interval_ms: @check_interval_ms_default
      ])

    name = Keyword.fetch!(options, :name)
    Assert.condition(is_atom(name), "name must be an atom, got: #{inspect(name)}")

    for key <- [
          :cell_count_max,
          :vehicle_count_max,
          :path_count_max,
          :check_interval_ms,
          :message_queue_length_max
        ] do
      value = Keyword.fetch!(options, key)
      Assert.condition(is_integer(value) and value >= 1, "#{key} must be a positive integer")
    end

    build_count_max = Keyword.fetch!(options, :path_build_count_max)
    Assert.condition(is_integer(build_count_max), "path_build_count_max must be an integer")
    Assert.condition(build_count_max >= 0, "path_build_count_max must not be negative")

    GenServer.start_link(__MODULE__, Map.new(options), name: name)
  end

  @impl GenServer
  def init(options) do
    # The process writes its tables in terminate/2, which a shutdown reaches
    # only in a process that traps exits.
    Process.flag(:trap_exit, true)

    # Callers of observe/2 read the bound and add to the skip count without a
    # message to this process.
    skip = %{counter: :counters.new(1, []), queue_length_max: options.message_queue_length_max}
    :persistent_term.put({__MODULE__, options.name}, skip)

    pace = %{
      options: options,
      skip_counter: skip.counter,
      table: new_table(options),
      pending: nil,
      table_is_full_logged: false,
      vehicles: %{},
      paths: %{}
    }

    {:ok, schedule_check(pace)}
  end

  @impl GenServer
  def handle_cast({:observe, reports}, pace) do
    pace = roll_over(pace)
    {:noreply, learn(pace, reports)}
  end

  @impl GenServer
  def handle_call(:write, _from, %{table: table, options: options} = pace) do
    case store(table, pace) do
      {:ok, _cell_count} = written ->
        empty = Table.new(%{date: table.date, cell_count_max: options.cell_count_max})
        flushed = %{pace | table: empty, table_is_full_logged: false}
        {:reply, written, flushed}

      {:error, _reason} = failed ->
        {:reply, failed, pace}
    end
  end

  @impl GenServer
  def handle_info(:check, pace) do
    {:noreply, pace |> roll_over() |> retry_pending() |> schedule_check()}
  end

  # The exit of a process the pace table is linked to, which it sees as a
  # message because it traps exits.
  def handle_info({:EXIT, _pid, _reason}, pace), do: {:noreply, pace}

  @impl GenServer
  def terminate(_reason, %{table: table, pending: pending} = pace) do
    _pending_result = store(pending, pace)
    _table_result = store(table, pace)
    :persistent_term.erase({__MODULE__, pace.options.name})
    :ok
  end

  defp roll_over(%{table: %{date: table_date}, options: options} = pace) do
    today = today(options)

    if Date.after?(today, table_date) do
      finished = pace.table
      pace = %{pace | table: new_table(options), table_is_full_logged: false}

      case store(finished, pace) do
        {:ok, _cell_count} -> pace
        {:error, _reason} -> set_aside(pace, finished)
      end
    else
      pace
    end
  end

  # The pending table is the one place a finished table waits for a write, so
  # a second one replaces it, and the replaced table is accounted for in a log.
  defp set_aside(%{pending: nil} = pace, finished), do: %{pace | pending: finished}

  defp set_aside(%{pending: dropped} = pace, finished) do
    Logger.error("Pace pending table dropped",
      date: Date.to_iso8601(dropped.date),
      cell_count: map_size(dropped.cells),
      meters_total: Table.meters_total(dropped)
    )

    %{pace | pending: finished}
  end

  defp retry_pending(%{pending: nil} = pace), do: pace

  defp retry_pending(%{pending: pending} = pace) do
    case store(pending, pace) do
      {:ok, _cell_count} -> %{pace | pending: nil}
      {:error, _reason} -> pace
    end
  end

  defp store(nil, _pace), do: {:ok, 0}

  defp store(table, %{options: options, skip_counter: skip_counter}) do
    if map_size(table.cells) == 0 do
      {:ok, 0}
    else
      file =
        Aggregate.build(%{
          table: table,
          node: options.node,
          file_id: file_id(options),
          written_at: now(options)
        })

      request = %{destination: file.destination, content: file.content}

      case Writer.write(request, options.write_options) do
        :ok ->
          skipped_count = :counters.get(skip_counter, 1)
          :counters.sub(skip_counter, 1, skipped_count)

          Logger.info("Pace table written",
            date: Date.to_iso8601(table.date),
            cell_count: file.cell_count,
            meters_total: file.meters_total,
            dropped_cell_count: table.dropped_count,
            skipped_observation_count: skipped_count
          )

          {:ok, file.cell_count}

        {:error, reason} ->
          Logger.error("Pace table not written",
            date: Date.to_iso8601(table.date),
            cell_count: file.cell_count,
            reason: inspect(reason)
          )

          {:error, reason}
      end
    end
  end

  defp learn(pace, []), do: pace

  defp learn(%{options: options} = pace, reports) do
    state = %{Observation.new(pace.table) | vehicles: pace.vehicles, paths: pace.paths}
    learned = Observation.learn(%{state: state, reports: reports, options: options})

    log_path_error(learned.path_error)

    %{pace | table: learned.table, vehicles: learned.vehicles, paths: learned.paths}
    |> log_table_full()
  end

  defp log_path_error(nil), do: :ok
  defp log_path_error(error), do: Logger.warning("Pace paths not read", err: error)

  defp log_table_full(
         %{table_is_full_logged: false, table: %{dropped_count: dropped_count} = table} = pace
       )
       when dropped_count > 0 do
    Logger.warning("Pace table full",
      date: Date.to_iso8601(table.date),
      cell_count_max: table.cell_count_max
    )

    %{pace | table_is_full_logged: true}
  end

  defp log_table_full(pace), do: pace

  defp new_table(options) do
    Table.new(%{date: today(options), cell_count_max: options.cell_count_max})
  end

  defp schedule_check(%{options: %{check_interval_ms: check_interval_ms}} = pace) do
    Process.send_after(self(), :check, check_interval_ms)
    pace
  end

  defp today(options), do: options |> now() |> DateTime.to_date()

  defp now(%{clock: clock}) do
    now = clock.()

    Assert.condition(
      match?(%DateTime{time_zone: "Etc/UTC"}, now),
      "the clock must return a UTC time"
    )

    now
  end

  defp file_id(%{file_id: file_id}) do
    id = file_id.()
    Assert.condition(is_binary(id), "file_id must return a string")
    id
  end
end
