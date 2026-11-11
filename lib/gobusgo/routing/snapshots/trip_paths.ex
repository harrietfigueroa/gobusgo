defmodule Gobusgo.Routing.Snapshots.TripPaths do
  @heap_words_max 8_000_000

  @moduledoc """
  The trip path files of one service date's snapshot: for every route the
  schedule view holds on the date and the route path view holds a path for,
  one shard of `Gobusgo.Routing.TripPathShard`, and one index of
  `Gobusgo.Routing.TripPathIndex` naming them. Each is stored through
  `Gobusgo.Writer` at `<directory>/<prefix>-<SHA-256>.bin.gz`.

  The shards are built in a process of their own, linked, with a full sweep
  at every collection and a heap capped at `:heap_words_max` words, which
  reads the views one route at a time, writes each shard as it is built, and
  returns only what the index needs, so no pass holds a date's schedules,
  paths, or shards together. A process that outgrows the cap is killed and
  logged as `Routing trip paths build killed` at `error`; one that exits for
  another reason, or whose write fails, is logged as `Routing trip paths
  build failed` at `error`. Either way the caller records its snapshot
  without the index.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.CompactSchedule
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteScheduleView
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.Packed
  alias Gobusgo.Routing.TripPathIndex
  alias Gobusgo.Routing.TripPathShard
  alias Gobusgo.Writer

  @typedoc "The files of a date: its index's manifest entry, or `nil` where no route has a path."
  @type built :: %{
          index_entry: map() | nil,
          trip_path_count: non_neg_integer(),
          shard_count: non_neg_integer()
        }

  @doc "The default heap cap of the process that builds the shards, in words."
  @spec heap_words_max() :: pos_integer()
  def heap_words_max, do: @heap_words_max

  @doc """
  Builds and writes the shards and the index of `input.service_date` under
  `input.directory`, reading the views `options` names: `:schedule_view`,
  `:stop_view`, `:route_path_view`, `:write_options`, and `:heap_words_max`.
  `:attempt` is the number of this try of the date's paths, 1 for the
  first, which the failure logs carry.
  Returns `{:built, built}`, `:killed` for a process that outgrew the cap,
  or `:failed`.
  """
  @spec run(%{service_date: Date.t(), directory: String.t(), options: Keyword.t()}) ::
          {:built, built()} | :killed | :failed
  def run(%{service_date: %Date{} = service_date, directory: directory, options: options})
      when is_binary(directory) and is_list(options) do
    heap_words_max = Keyword.fetch!(options, :heap_words_max)
    attempt = Keyword.fetch!(options, :attempt)
    Assert.condition(is_integer(attempt), "attempt must be an integer")
    Assert.condition(attempt >= 1, "attempt must be at least 1, got: #{attempt}")
    Assert.condition(is_integer(heap_words_max), "the heap cap must be an integer")
    Assert.condition(heap_words_max > 0, "the heap cap must be positive, got: #{heap_words_max}")

    input = %{service_date: service_date, directory: directory, options: options}

    case capped(input, heap_words_max) do
      {:ok, {:ok, shards}} ->
        write_index(Enum.reverse(shards), input)

      {:ok, {:error, :write_failed}} ->
        Logger.error("Routing trip paths build failed",
          service_date: Date.to_iso8601(service_date),
          attempt: Keyword.fetch!(options, :attempt),
          reason: "write_failed"
        )

        :failed

      {:exit, :killed} ->
        Logger.error("Routing trip paths build killed",
          service_date: Date.to_iso8601(service_date),
          attempt: Keyword.fetch!(options, :attempt),
          heap_words_max: heap_words_max
        )

        :killed

      {:exit, reason} ->
        Logger.error("Routing trip paths build failed",
          service_date: Date.to_iso8601(service_date),
          attempt: Keyword.fetch!(options, :attempt),
          err: exit_error(reason)
        )

        :failed
    end
  end

  # The process is linked, so it dies with a caller that is killed; the
  # caller traps exits while it waits, so the kill of the process reaches it
  # as a message.
  defp capped(input, heap_words_max) do
    parent = self()
    tag = make_ref()
    trapping = Process.flag(:trap_exit, true)

    {pid, monitor} =
      :erlang.spawn_opt(fn -> send(parent, {tag, build_shards(input)}) end, [
        :link,
        :monitor,
        fullsweep_after: 0,
        max_heap_size: %{size: heap_words_max, kill: true, error_logger: true}
      ])

    result =
      receive do
        {^tag, outcome} -> {:ok, outcome}
        {:DOWN, ^monitor, :process, ^pid, reason} -> {:exit, reason}
      end

    Process.demonitor(monitor, [:flush])

    receive do
      {:EXIT, ^pid, _reason} -> :ok
    end

    Process.flag(:trap_exit, trapping)
    result
  end

  defp exit_error({%{__exception__: true} = exception, stacktrace}) do
    %{message: Exception.message(exception), stack: Exception.format_stacktrace(stacktrace)}
  end

  defp exit_error(reason), do: %{message: Exception.format_exit(reason), stack: ""}

  defp build_shards(%{service_date: service_date, options: options} = input) do
    schedule_view = Keyword.fetch!(options, :schedule_view)
    route_ids = RouteScheduleView.route_ids_on(schedule_view, service_date)

    Enum.reduce_while(route_ids, {:ok, []}, fn route_id, {:ok, shards} ->
      case route_shard(route_id, input) do
        :skipped -> {:cont, {:ok, shards}}
        {:ok, shard} -> {:cont, {:ok, [shard | shards]}}
        :write_failed -> {:halt, {:error, :write_failed}}
      end
    end)
  end

  # One route's shard, written; `:skipped` for a route the views hold no
  # schedule or path of, or none of whose trips has a path.
  defp route_shard(route_id, %{service_date: service_date, options: options} = input) do
    schedule_view = Keyword.fetch!(options, :schedule_view)
    fetch = RouteScheduleView.schedule(schedule_view, route_id, service_date)
    route_path = FetchView.current_fetch(Keyword.fetch!(options, :route_path_view), route_id)

    case {fetch, route_path} do
      {nil, _route_path} ->
        :skipped

      {_fetch, nil} ->
        :skipped

      {%{schedule: schedule}, route_path} ->
        trips = trips(schedule)

        built =
          TripPathShard.build(%{
            polylines: polylines(route_path),
            stop_positions: stop_positions(trips, Keyword.fetch!(options, :stop_view)),
            trips: trips
          })

        write_shard(built, route_id, input)
    end
  end

  defp trips(schedule) do
    for trip <- schedule.trips do
      %{id: trip.id, stop_times: CompactSchedule.stop_times(schedule, trip)}
    end
  end

  defp polylines(route_path) do
    group_polylines =
      for grouping <- route_path.stop_groupings,
          group <- grouping["stopGroups"],
          polyline <- group["polylines"],
          do: polyline["points"]

    Enum.map(route_path.polylines, & &1["points"]) ++ group_polylines
  end

  defp stop_positions(trips, stop_view) do
    stop_ids =
      for trip <- trips, stop_time <- trip.stop_times, uniq: true, do: stop_time.stop_id

    for stop_id <- stop_ids,
        held = StopView.stop(stop_view, stop_id),
        held != nil,
        into: %{},
        do: {stop_id, {held.stop["lat"], held.stop["lon"]}}
  end

  defp write_shard(:no_paths, _route_id, _input), do: :skipped

  defp write_shard({:ok, built}, route_id, %{directory: directory, options: options}) do
    stored = Packed.stored(built.content)

    destination =
      Packed.destination(%{directory: directory, kind: TripPathShard.kind(), stored: stored})

    case write(destination, stored, options) do
      true ->
        {:ok,
         %{
           record: %{
             route_id: route_id,
             path: "/" <> destination,
             byte_size: stored.byte_size,
             sha256: stored.sha256
           },
           trip_count: built.trip_count
         }}

      false ->
        :write_failed
    end
  end

  defp write_index([], _input),
    do: {:built, %{index_entry: nil, trip_path_count: 0, shard_count: 0}}

  defp write_index(shards, %{service_date: service_date, directory: directory, options: options}) do
    content = TripPathIndex.build(Enum.map(shards, & &1.record))
    stored = Packed.stored(content)

    destination =
      Packed.destination(%{directory: directory, kind: TripPathIndex.kind(), stored: stored})

    case write(destination, stored, options) do
      true ->
        {:built,
         %{
           index_entry: Packed.file_entry("/" <> destination, stored),
           trip_path_count: Enum.sum(Enum.map(shards, & &1.trip_count)),
           shard_count: length(shards)
         }}

      false ->
        Logger.error("Routing trip paths build failed",
          service_date: Date.to_iso8601(service_date),
          attempt: Keyword.fetch!(options, :attempt),
          reason: "write_failed"
        )

        :failed
    end
  end

  # A destination that exists holds the same content, since its name is the
  # content's hash.
  defp write(destination, %{content: content}, options) do
    write_options = Keyword.fetch!(options, :write_options)

    case Writer.write(%{destination: destination, content: content}, write_options) do
      :ok -> true
      {:error, :already_exists} -> true
      {:error, _reason} -> false
    end
  end
end
