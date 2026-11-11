defmodule Gobusgo.Routing.Snapshots.Build do
  @date_heap_words_max 20_000_000
  @trip_path_heap_words_max Gobusgo.Routing.Snapshots.TripPaths.heap_words_max()

  @moduledoc """
  One run of the routing snapshot build: for every service date the
  schedule view holds, builds the snapshot from that date's schedules and
  the previous date's, writes its files, and records its manifest entry.

  A date is passed over when the SHA-256 of its inputs, the request
  identifiers of both dates' schedules, the positions and names of the stop
  view's stops, the names of the route view's routes, the agency view's
  agency names, and the request identifiers of the route path view's paths
  of the routes the date's schedules name, is that of its current entry and
  the entry was built today.
  The names are hashed as values, so a view fetched again unchanged builds
  nothing. A file whose destination already exists holds the same content,
  since its name is the content's hash, and counts as written. A date whose
  files are not all written keeps the entry it had. Entries of dates the
  view no longer holds are dropped.

  ## Logs

  One line per run that builds or fails: `Routing snapshots built` at
  `info`, or `Routing snapshots not built` at `error` when a date's files
  were not written, with the counts built, passed over, and failed, the
  connection count of the dates built, the counts of trip paths and of trip
  path shards written, the time the trip path builds took in milliseconds,
  and the count of trip path builds that were killed or failed, and the
  time taken. A run that builds nothing and fails nothing logs `debug`.

  Each date is built in a process of its own whose heap is capped at
  `:date_heap_words_max` words. A date whose build outgrows the cap is
  killed, logged as `Routing snapshot build killed` at `error`, and counted
  as failed; the dates after it are still built.

  Once a date's snapshot files are written and its process has ended, the
  trip path files of `Gobusgo.Routing.Snapshots.TripPaths` are built in a
  process of their own whose heap is capped at `:trip_path_heap_words_max`
  words, and written before the entry is recorded with them, as
  `files.tripPaths`. A trip path build that is killed or fails leaves the
  entry recorded without `files.tripPaths`, and the snapshot stays.

  ## Options

    * `:server` (required): the `Gobusgo.Routing.Snapshots` process.
    * `:schedule_view`, `:stop_view`, `:route_view`, and `:agency_view`:
      the views read. Default to `Gobusgo.OneBusAway.RouteScheduleView`,
      `Gobusgo.OneBusAway.StopView`, `Gobusgo.OneBusAway.RouteView`, and
      `Gobusgo.OneBusAway.AgencyView`.
    * `:clock`: returns the current UTC time. Defaults to
      `DateTime.utc_now/0`.
    * `:write_options`: options for `Gobusgo.Writer.write/2`.
    * `:date_heap_words_max`: the heap cap of a date's build, in words.
      Defaults to #{@date_heap_words_max}.
    * `:route_path_view`: the view of the route paths the trip paths are
      built over. Defaults to `Gobusgo.OneBusAway.RoutePathView`.
    * `:trip_path_heap_words_max`: the heap cap of a date's trip path
      build, in words. Defaults to #{@trip_path_heap_words_max}.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteScheduleView
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.Routing.Names
  alias Gobusgo.Routing.Snapshot
  alias Gobusgo.Routing.Snapshots
  alias Gobusgo.Routing.Snapshots.TripPaths
  alias Gobusgo.Routing.Timetable
  alias Gobusgo.Routing.Transfers
  alias Gobusgo.Writer

  @type counts :: %{
          built_count: non_neg_integer(),
          unchanged_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          connection_count: non_neg_integer(),
          trip_path_count: non_neg_integer(),
          trip_path_shard_count: non_neg_integer(),
          trip_path_elapsed_ms: non_neg_integer(),
          trip_path_failed_count: non_neg_integer()
        }

  @doc "Builds the snapshot of every held service date whose inputs changed."
  @spec run(Keyword.t()) :: {:ok, counts()} | {:error, counts()}
  def run(options) when is_list(options) do
    options =
      Keyword.validate!(options, [
        :server,
        schedule_view: RouteScheduleView,
        stop_view: StopView,
        route_view: Gobusgo.OneBusAway.RouteView,
        agency_view: AgencyView,
        clock: &DateTime.utc_now/0,
        write_options: [],
        date_heap_words_max: @date_heap_words_max,
        route_path_view: Gobusgo.OneBusAway.RoutePathView,
        trip_path_heap_words_max: @trip_path_heap_words_max
      ])

    started_ms = System.monotonic_time(:millisecond)
    server = Keyword.fetch!(options, :server)
    schedule_view = Keyword.fetch!(options, :schedule_view)
    now = Keyword.fetch!(options, :clock).()
    today = DateTime.to_date(now)
    dates = RouteScheduleView.held_dates(schedule_view)
    held_stops = StopView.current(Keyword.fetch!(options, :stop_view))
    positions = positions(held_stops)

    sources =
      packed_sources(%{
        stops: stop_names(held_stops),
        routes: route_names(Keyword.fetch!(options, :route_view)),
        agency_names: agency_names(Keyword.fetch!(options, :agency_view))
      })

    built = Snapshots.built(server)

    outcomes =
      for date <- dates do
        date_outcome(%{
          date: date,
          built: Map.get(built, date),
          positions: positions,
          sources: sources,
          today: today,
          now: now,
          options: options
        })
      end

    :ok = Snapshots.retain(server, dates)

    counts = %{
      built_count: Enum.count(outcomes, &match?({:built, _count}, &1)),
      unchanged_count: Enum.count(outcomes, &(&1 == :unchanged)),
      failed_count: Enum.count(outcomes, &(&1 == :failed)),
      connection_count: Enum.sum(for {:built, built} <- outcomes, do: built.connection_count),
      trip_path_count: Enum.sum(for {:built, built} <- outcomes, do: built.trip_path_count),
      trip_path_shard_count:
        Enum.sum(for {:built, built} <- outcomes, do: built.trip_path_shard_count),
      trip_path_elapsed_ms:
        Enum.sum(for {:built, built} <- outcomes, do: built.trip_path_elapsed_ms),
      trip_path_failed_count:
        Enum.count(outcomes, &match?({:built, %{trip_paths_failed: true}}, &1))
    }

    log(counts, System.monotonic_time(:millisecond) - started_ms)

    if counts.failed_count == 0, do: {:ok, counts}, else: {:error, counts}
  end

  # A date is built in a process of its own, so its schedules and timetable
  # are freed before the next date's are read, under a heap cap, so a build
  # that outgrows it is killed alone and the date counts as failed, and with
  # a full sweep at every collection, so garbage of the build's earlier steps
  # is not kept in an old generation. The process is linked, so it dies with
  # a run that is killed; the run traps exits while it waits, so the kill of
  # the process reaches it as a message, and any other exit is raised again.
  defp date_outcome(%{options: options} = input) do
    heap_words_max = Keyword.fetch!(options, :date_heap_words_max)
    Assert.condition(is_integer(heap_words_max), "date_heap_words_max must be an integer")

    Assert.condition(
      heap_words_max > 0,
      "date_heap_words_max must be positive, got: #{heap_words_max}"
    )

    parent = self()
    tag = make_ref()
    trapping = Process.flag(:trap_exit, true)

    {pid, monitor} =
      :erlang.spawn_opt(fn -> send(parent, {tag, date_outcome_callback(input)}) end, [
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

    case result do
      {:ok, {:written, written}} ->
        trip_paths_outcome(written, input)

      {:ok, outcome} ->
        outcome

      {:exit, :killed} ->
        Logger.error("Routing snapshot build killed",
          service_date: Date.to_iso8601(input.date),
          heap_words_max: heap_words_max
        )

        :failed

      {:exit, reason} ->
        exit(reason)
    end
  end

  defp date_outcome_callback(%{date: date, options: options} = input) do
    schedule_view = Keyword.fetch!(options, :schedule_view)
    today = input.today
    schedules = packed_schedules(schedule_view, date)
    previous = packed_schedules(schedule_view, Date.add(date, -1))
    route_path_view = Keyword.fetch!(options, :route_path_view)

    route_paths =
      for fetch <- schedules, do: {fetch.id, FetchView.request_id(route_path_view, fetch.id)}

    inputs_sha256 =
      inputs_sha256(%{
        schedules: schedules,
        previous: previous,
        route_paths: route_paths,
        positions: input.positions,
        sources: input.sources
      })

    case input.built do
      %{inputs_sha256: ^inputs_sha256, built_on: ^today} ->
        :unchanged

      _other ->
        build_date(%{
          date: date,
          schedules: schedules,
          previous: previous,
          positions: input.positions,
          sources: input.sources,
          inputs_sha256: inputs_sha256,
          now: input.now,
          options: options
        })
    end
  end

  # The fetches of `date` as the view holds them when they are read, each
  # schedule packed into a binary, which is stored off the process heap.
  # They are read one route at a time, so the heap holds one schedule at a
  # time, and the build reads every pass from these fetches, so a fetch the
  # view takes in during the build changes nothing it builds.
  defp packed_schedules(schedule_view, date) do
    for route_id <- RouteScheduleView.route_ids_on(schedule_view, date),
        fetch = RouteScheduleView.schedule(schedule_view, route_id, date),
        fetch != nil do
      %{
        id: fetch.id,
        service_date: fetch.service_date,
        request_id: fetch.request_id,
        fetched_at: fetch.fetched_at,
        packed_schedule: :erlang.term_to_binary(fetch.schedule)
      }
    end
  end

  # The schedules of `fetches` as a stream that unpacks each when it is
  # reached, so a pass over them holds one unpacked schedule at a time.
  defp unpacked_schedules(fetches) do
    Stream.map(fetches, &:erlang.binary_to_term(&1.packed_schedule, [:safe]))
  end

  defp positions(held_stops) do
    for %{id: id, stop: %{"lat" => lat, "lon" => lon}} <- held_stops,
        into: %{},
        do: {id, %{lat: lat, lon: lon}}
  end

  defp stop_names(held_stops) do
    for %{id: id, stop: stop} <- held_stops,
        into: %{},
        do: {id, %{name: stop["name"], code: stop["code"]}}
  end

  defp route_names(route_view) do
    for %{routes: routes} <- FetchView.current(route_view),
        {route_id, route} <- routes,
        into: %{} do
      {route_id,
       %{
         short_name: route["shortName"],
         long_name: route["longName"],
         color: route["color"],
         agency_id: route["agencyId"]
       }}
    end
  end

  defp agency_names(agency_view) do
    case AgencyView.current(agency_view) do
      nil ->
        %{}

      %{agencies: agencies} ->
        for {id, agency} <- agencies, into: %{}, do: {id, agency["name"]}
    end
  end

  # The names reach each date's process as one binary, which is stored off
  # the process heap, and are decoded only once the timetable is built, so
  # they take no room under the heap cap while the timetable's build peaks.
  # They are sorted before they are packed, so the same names pack to the
  # same binary and hash to the same SHA-256.
  defp packed_sources(%{stops: stops, routes: routes, agency_names: agency_names}) do
    packed =
      :erlang.term_to_binary({Enum.sort(stops), Enum.sort(routes), Enum.sort(agency_names)})

    %{packed: packed, sha256: :crypto.hash(:sha256, packed)}
  end

  defp unpacked_sources(%{packed: packed}) do
    {stops, routes, agency_names} = :erlang.binary_to_term(packed, [:safe])
    %{stops: Map.new(stops), routes: Map.new(routes), agency_names: Map.new(agency_names)}
  end

  defp inputs_sha256(
         %{schedules: schedules, previous: previous, route_paths: route_paths} = inputs
       ) do
    requests =
      for fetch <- schedules ++ previous, do: {fetch.id, fetch.service_date, fetch.request_id}

    hashed =
      {Enum.sort(requests), Enum.sort(route_paths), Enum.sort(inputs.positions),
       inputs.sources.sha256}

    :crypto.hash(:sha256, :erlang.term_to_binary(hashed))
  end

  defp build_date(%{date: date, schedules: schedules, previous: previous, now: now} = input) do
    today_schedules = unpacked_schedules(schedules)
    previous_schedules = unpacked_schedules(previous)

    timetable =
      Timetable.build(%{
        service_date: date,
        schedules: today_schedules,
        previous_schedules: previous_schedules
      })

    fetch_times = Enum.map(schedules ++ previous, & &1.fetched_at)
    walking_links = Transfers.walking_links(timetable.stop_ids, input.positions)
    sources = unpacked_sources(input.sources)

    headsigns =
      Names.headsigns(%{
        schedules: today_schedules,
        previous_schedules: previous_schedules
      })

    names =
      Names.build(%{
        stop_ids: timetable.stop_ids,
        trips: timetable.trips,
        headsigns: headsigns,
        stops: sources.stops,
        routes: sources.routes,
        agency_names: sources.agency_names
      })

    %{files: files, entry: entry} =
      Snapshot.build(%{
        timetable: timetable,
        walking_links: walking_links,
        positions: input.positions,
        names: names,
        built_at: now,
        fetched_at_oldest: Enum.min(fetch_times, DateTime),
        fetched_at_newest: Enum.max(fetch_times, DateTime)
      })

    write_options = Keyword.fetch!(input.options, :write_options)

    if Enum.all?(files, &written?(&1, write_options)) do
      {:written,
       %{
         entry: entry,
         inputs_sha256: input.inputs_sha256,
         connection_count: timetable.connection_count
       }}
    else
      :failed
    end
  end

  # The trip paths are built once the date's process has ended and its heap
  # is freed, and written before the entry names them.
  defp trip_paths_outcome(written, %{date: date, now: now, options: options}) do
    started_ms = System.monotonic_time(:millisecond)

    outcome =
      TripPaths.run(%{
        service_date: date,
        directory: Snapshot.directory(now),
        options:
          Keyword.take(options, [:schedule_view, :stop_view, :route_path_view, :write_options]) ++
            [heap_words_max: Keyword.fetch!(options, :trip_path_heap_words_max)]
      })

    elapsed_ms = System.monotonic_time(:millisecond) - started_ms
    counts = trip_path_counts(outcome, elapsed_ms)

    :ok =
      Snapshots.record(Keyword.fetch!(options, :server), %{
        service_date: date,
        entry: with_trip_paths(written.entry, outcome),
        inputs_sha256: written.inputs_sha256,
        built_on: DateTime.to_date(now)
      })

    {:built, Map.put(counts, :connection_count, written.connection_count)}
  end

  defp with_trip_paths(entry, {:built, %{index_entry: index_entry}}) when is_map(index_entry) do
    Map.update!(entry, "files", &Map.put(&1, "tripPaths", index_entry))
  end

  defp with_trip_paths(entry, _outcome), do: entry

  defp trip_path_counts({:built, built}, elapsed_ms) do
    %{
      trip_path_count: built.trip_path_count,
      trip_path_shard_count: built.shard_count,
      trip_path_elapsed_ms: elapsed_ms,
      trip_paths_failed: false
    }
  end

  defp trip_path_counts(failure, elapsed_ms) when failure in [:killed, :failed] do
    %{
      trip_path_count: 0,
      trip_path_shard_count: 0,
      trip_path_elapsed_ms: elapsed_ms,
      trip_paths_failed: true
    }
  end

  defp written?(%{destination: destination, content: content}, write_options) do
    case Writer.write(%{destination: destination, content: content}, write_options) do
      :ok -> true
      {:error, :already_exists} -> true
      {:error, _reason} -> false
    end
  end

  defp log(counts, elapsed_ms) do
    properties = Map.to_list(counts) ++ [elapsed_ms: elapsed_ms]

    cond do
      counts.failed_count >= 1 -> Logger.error("Routing snapshots not built", properties)
      counts.built_count >= 1 -> Logger.info("Routing snapshots built", properties)
      true -> Logger.debug("Routing snapshots unchanged", properties)
    end
  end
end
