defmodule Gobusgo.OneBusAway.TripPaths do
  @request_count_max 100
  @heap_words_max 6_000_000
  @deadline_ms 5_000
  @start_wait_ms 1_000
  @half_day_ms 43_200_000

  @moduledoc """
  Serves the paths of running trips, as `Gobusgo.OneBusAway.TripPath`
  builds them, from the route path view, the stop view, and the route
  schedule view, with no request to OneBusAway.

  A request names a trip by its identifier, its route, and its service
  date as the start of its service day in milliseconds since the Unix
  epoch, the value OneBusAway sends as a trip status's `serviceDate` and a
  schedule's `scheduleDate`. A trip's path is the same for every page, so
  the paths built are kept in `Gobusgo.OneBusAway.TripPathCache` by trip
  and service date. A path the cache holds is served while the route path
  and the schedule it was built from are still their views' current
  fetches; otherwise it is built again. A stop that another route's fetch
  moves reaches the path once this route's path or schedule is fetched
  again.

  The paths the cache does not hold are built in a process of its own,
  under the builder supervisor, whose bound on children is the bound on
  builds running at once on the node. The process's heap is capped at
  `:heap_words_max` words and collected in full at every collection, so
  the decoded polylines and the copied schedules of a build leave with the
  process and never grow the caller's heap. A build that outgrows the cap
  or passes `:deadline_ms` is killed. A request with nothing to build
  starts no process.

  ## Options

    * `:route_path_view`, `:stop_view`, `:schedule_view`: the views read.
      Default to `Gobusgo.OneBusAway.RoutePathView`,
      `Gobusgo.OneBusAway.StopView`, and
      `Gobusgo.OneBusAway.RouteScheduleView`.
    * `:cache`: the `Gobusgo.OneBusAway.TripPathCache`. Defaults to the
      module's name.
    * `:builders`: the `Task.Supervisor` the builds run under. Defaults to
      `Gobusgo.OneBusAway.TripPathBuilders`.
    * `:heap_words_max`: the heap cap of a build, in words. Defaults to
      #{@heap_words_max}.
    * `:deadline_ms`: how long a build may take. Defaults to
      #{@deadline_ms} ms.

  A request that builds logs `debug` `Trip paths served` with the counts of
  paths served from the cache and built, the trips missing a path, and the
  polylines passed over. A build that is killed logs `error`
  `Trip paths not built` with the reason and the count of trips it was
  building; the request's other paths are not served.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.CompactSchedule
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteScheduleView
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.OneBusAway.TripPath
  alias Gobusgo.OneBusAway.TripPathCache

  @typedoc "One trip whose path is asked for."
  @type request :: %{trip_id: String.t(), route_id: String.t(), service_date_ms: integer()}

  @typedoc "A trip's path, in `Gobusgo.OneBusAway.TripPath.encode/1`'s form."
  @type path :: %{
          trip_id: String.t(),
          route_id: String.t(),
          service_date_ms: integer(),
          points: String.t(),
          stops: String.t()
        }

  @typedoc """
  Why a trip has no path:

    * `:route_path_missing`: the route path view holds no fetch of the
      trip's route.
    * `:schedule_missing`: the schedule view holds no schedule of the
      trip's route on its service date, or the schedule does not list the
      trip.
    * `:stop_positions_missing`: the stop view lacks a stop of the trip.
  """
  @type reason :: :route_path_missing | :schedule_missing | :stop_positions_missing

  @type missing :: %{
          trip_id: String.t(),
          route_id: String.t(),
          service_date_ms: integer(),
          reason: reason()
        }

  @typedoc """
    * `:busy`: every builder the supervisor allows is running.
    * `:killed`: the build outgrew its heap cap.
    * `:timeout`: the build passed its deadline.
  """
  @type error :: :busy | :killed | :timeout

  @doc "The most trips one request names."
  @spec request_count_max() :: pos_integer()
  def request_count_max, do: @request_count_max

  @doc """
  Returns the path of each trip of `requests`, at most
  #{@request_count_max}, once per trip and service date, and the trips
  that have none, with the reason.
  """
  @spec fetch([request()], Keyword.t()) ::
          {:ok, %{paths: [path()], missing: [missing()]}} | {:error, error()}
  def fetch(requests, options \\ []) when is_list(requests) and is_list(options) do
    options =
      Keyword.validate!(options,
        route_path_view: Gobusgo.OneBusAway.RoutePathView,
        stop_view: StopView,
        schedule_view: RouteScheduleView,
        cache: TripPathCache,
        builders: Gobusgo.OneBusAway.TripPathBuilders,
        heap_words_max: @heap_words_max,
        deadline_ms: @deadline_ms
      )

    request_count = length(requests)

    Assert.condition(
      request_count <= @request_count_max,
      "a request names at most #{@request_count_max} trips, got: #{request_count}"
    )

    Enum.each(requests, &assert_request/1)
    unique = Enum.uniq_by(requests, &key/1)
    looked_up = Enum.map(unique, &{&1, held_path(&1, options)})
    held_paths = for {_request, path} <- looked_up, path != nil, do: path
    unheld = for {request, nil} <- looked_up, do: request

    case unheld do
      [] ->
        {:ok, %{paths: held_paths, missing: []}}

      _unheld ->
        unheld
        |> build(options)
        |> served(%{held_paths: held_paths, request_count: length(unheld)})
    end
  end

  defp assert_request(%{trip_id: trip_id, route_id: route_id, service_date_ms: service_date_ms}) do
    Assert.condition(is_binary(trip_id), "a trip identifier must be a string")
    Assert.condition(is_binary(route_id), "a route identifier must be a string")
    Assert.condition(is_integer(service_date_ms), "a service date must be an integer")
  end

  defp key(%{trip_id: trip_id, service_date_ms: service_date_ms}), do: {trip_id, service_date_ms}

  # The service day starts at local midnight, which lies within twelve
  # hours of midnight UTC on the same date for every zone from UTC-11 to
  # UTC+12, so the UTC date twelve hours later is the service date. The
  # schedule's own start is compared with the request's below.
  defp service_date(service_date_ms) do
    (service_date_ms + @half_day_ms)
    |> DateTime.from_unix!(:millisecond)
    |> DateTime.to_date()
  end

  defp held_path(request, options) do
    held = TripPathCache.lookup(Keyword.fetch!(options, :cache), key(request))
    held_current(held, request, options)
  end

  defp held_current(nil, _request, _options), do: nil

  defp held_current(
         %{path: %{route_id: route_id}} = held,
         %{route_id: route_id} = request,
         options
       ) do
    date = service_date(request.service_date_ms)
    schedule_view = Keyword.fetch!(options, :schedule_view)
    schedule_request_id = RouteScheduleView.request_id(schedule_view, route_id, date)

    route_path_request_id =
      FetchView.request_id(Keyword.fetch!(options, :route_path_view), route_id)

    schedule_current = schedule_request_id == held.schedule_request_id
    route_path_current = route_path_request_id == held.route_path_request_id
    current = schedule_current and route_path_current

    case current do
      true -> held.path
      false -> nil
    end
  end

  defp held_current(_held_for_another_route, _request, _options), do: nil

  defp served({:ok, built}, %{held_paths: held_paths}) do
    Logger.debug("Trip paths served",
      held_count: length(held_paths),
      built_count: length(built.paths),
      missing_count: length(built.missing),
      polyline_skipped_count: built.polyline_skipped_count
    )

    {:ok, %{paths: held_paths ++ built.paths, missing: built.missing}}
  end

  defp served({:error, :busy}, _context), do: {:error, :busy}

  defp served({:error, reason}, %{request_count: request_count}) do
    Logger.error("Trip paths not built", reason: reason, request_count: request_count)
    {:error, reason}
  end

  # Runs the build in a process of its own, which hands back its outcome
  # as a message, and kills it at the deadline. The process waits to be
  # told to start until the caller monitors it, so an exit at its first
  # collection reaches the caller with its reason.
  defp build(requests, options) do
    parent = self()
    tag = make_ref()
    deadline_ms = Keyword.fetch!(options, :deadline_ms)
    heap_words_max = Keyword.fetch!(options, :heap_words_max)
    Assert.condition(is_integer(heap_words_max), "heap_words_max must be an integer")

    Assert.condition(
      heap_words_max > 0,
      "heap_words_max must be positive, got: #{heap_words_max}"
    )

    builder = fn ->
      receive do
        {^tag, :start} ->
          Process.flag(:max_heap_size, %{size: heap_words_max, kill: true, error_logger: false})
          Process.flag(:fullsweep_after, 0)
          send(parent, {tag, {:built, build_routes(requests, options)}})
      after
        @start_wait_ms -> :ok
      end
    end

    case Task.Supervisor.start_child(Keyword.fetch!(options, :builders), builder,
           restart: :temporary
         ) do
      {:ok, pid} ->
        await_build(%{pid: pid, tag: tag, deadline_ms: deadline_ms})

      {:error, :max_children} ->
        {:error, :busy}
    end
  end

  defp await_build(%{pid: pid, tag: tag, deadline_ms: deadline_ms}) do
    monitor = Process.monitor(pid)
    send(pid, {tag, :start})

    receive do
      {^tag, {:built, built}} ->
        Process.demonitor(monitor, [:flush])
        {:ok, built}

      {:DOWN, ^monitor, :process, ^pid, :killed} ->
        {:error, :killed}

      # A build that crashes has met a programmer error, which crashes the
      # caller in turn.
      {:DOWN, ^monitor, :process, ^pid, reason} ->
        exit({:trip_path_build_crashed, reason})
    after
      deadline_ms ->
        Process.exit(pid, :kill)
        Process.demonitor(monitor, [:flush])

        receive do
          {^tag, {:built, _built}} -> :ok
        after
          0 -> :ok
        end

        {:error, :timeout}
    end
  end

  defp build_routes(requests, options) do
    initial = %{paths: [], missing: [], polyline_skipped_count: 0}

    requests
    |> Enum.group_by(& &1.route_id)
    |> Enum.reduce(initial, fn {route_id, route_requests}, built ->
      route_built = build_route(%{route_id: route_id, requests: route_requests}, options)

      %{
        paths: route_built.paths ++ built.paths,
        missing: route_built.missing ++ built.missing,
        polyline_skipped_count: route_built.polyline_skipped_count + built.polyline_skipped_count
      }
    end)
  end

  defp build_route(%{route_id: route_id, requests: requests}, options) do
    route_path_view = Keyword.fetch!(options, :route_path_view)

    case FetchView.current_fetch(route_path_view, route_id) do
      nil ->
        %{
          paths: [],
          missing: Enum.map(requests, &missing(&1, :route_path_missing)),
          polyline_skipped_count: 0
        }

      route_path ->
        requests
        |> Enum.group_by(& &1.service_date_ms)
        |> Enum.map(fn {service_date_ms, date_requests} ->
          build_date(
            %{route_path: route_path, service_date_ms: service_date_ms, requests: date_requests},
            options
          )
        end)
        |> Enum.reduce(%{paths: [], missing: [], polyline_skipped_count: 0}, fn date_built,
                                                                                built ->
          %{
            paths: date_built.paths ++ built.paths,
            missing: date_built.missing ++ built.missing,
            polyline_skipped_count:
              date_built.polyline_skipped_count + built.polyline_skipped_count
          }
        end)
    end
  end

  defp build_date(%{route_path: route_path, service_date_ms: service_date_ms} = input, options) do
    route_id = route_path.id
    date = service_date(service_date_ms)
    fetch = RouteScheduleView.schedule(Keyword.fetch!(options, :schedule_view), route_id, date)

    schedule =
      case fetch do
        %{schedule: %{schedule_date_ms: ^service_date_ms} = schedule} -> schedule
        _other -> nil
      end

    trips = scheduled_trips(schedule, input.requests)
    {scheduled, unscheduled} = Enum.split_with(input.requests, &Map.has_key?(trips, &1.trip_id))
    unscheduled_missing = Enum.map(unscheduled, &missing(&1, :schedule_missing))

    case scheduled do
      [] ->
        %{paths: [], missing: unscheduled_missing, polyline_skipped_count: 0}

      _scheduled ->
        built =
          TripPath.build_route(%{
            polylines: polylines(route_path),
            stop_positions: stop_positions(trips, Keyword.fetch!(options, :stop_view)),
            trips: Map.values(trips)
          })

        versions = %{
          schedule_request_id: fetch.request_id,
          route_path_request_id: route_path.request_id
        }

        outcomes = Enum.map(scheduled, &{&1, Map.fetch!(built.paths, &1.trip_id)})
        paths = for {request, {:ok, trip_path}} <- outcomes, do: encoded_path(request, trip_path)
        missing = for {request, {:error, reason}} <- outcomes, do: missing(request, reason)
        held = Enum.map(paths, &{key(&1), Map.put(versions, :path, &1)})
        :ok = TripPathCache.put(Keyword.fetch!(options, :cache), held)

        %{
          paths: paths,
          missing: unscheduled_missing ++ missing,
          polyline_skipped_count: built.polyline_skipped_count
        }
    end
  end

  defp scheduled_trips(nil, _requests), do: %{}

  defp scheduled_trips(schedule, requests) do
    trip_ids = MapSet.new(requests, & &1.trip_id)

    for trip <- schedule.trips, MapSet.member?(trip_ids, trip.id), into: %{} do
      {trip.id, %{id: trip.id, stop_times: CompactSchedule.stop_times(schedule, trip)}}
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
      for {_trip_id, trip} <- trips,
          stop_time <- trip.stop_times,
          uniq: true,
          do: stop_time.stop_id

    for stop_id <- stop_ids,
        held = StopView.stop(stop_view, stop_id),
        held != nil,
        into: %{},
        do: {stop_id, {held.stop["lat"], held.stop["lon"]}}
  end

  defp encoded_path(request, trip_path) do
    %{
      trip_id: request.trip_id,
      route_id: request.route_id,
      service_date_ms: request.service_date_ms,
      points: trip_path.points,
      stops: trip_path.stops
    }
  end

  defp missing(request, reason) do
    %{
      trip_id: request.trip_id,
      route_id: request.route_id,
      service_date_ms: request.service_date_ms,
      reason: reason
    }
  end
end
