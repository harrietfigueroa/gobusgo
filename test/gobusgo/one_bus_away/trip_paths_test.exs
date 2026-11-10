defmodule Gobusgo.OneBusAway.TripPathsTest do
  # Verifies serving trip paths from the views: each test starts its own
  # route path view, stop view, schedule view, cache, and builder
  # supervisor, fills the views from the stored loop route 1_7994 of
  # 2026-11-09 with records built as the processors build them, leaves out
  # the one view or fetch its case is about, and reads what a request gets.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RoutePathBatch
  alias Gobusgo.OneBusAway.RoutePaths
  alias Gobusgo.OneBusAway.RouteScheduleBatch
  alias Gobusgo.OneBusAway.RouteSchedules
  alias Gobusgo.OneBusAway.RouteScheduleView
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.OneBusAway.TripPath
  alias Gobusgo.OneBusAway.TripPathCache
  alias Gobusgo.OneBusAway.TripPaths

  @fixture_directory Path.expand("../../fixtures/one_bus_away/trip_path", __DIR__)
  @route_id "1_7994"
  @trip_id "1_1137791"
  @service_date ~D[2026-11-09]
  @service_date_ms 1_794_211_200_000
  @day_ms 86_400_000
  @fetched_at ~U[2026-11-09 04:20:32Z]
  @heap_words_tiny 1_000

  setup context do
    names =
      for name <- [:route_path_view, :stop_view, :schedule_view, :cache, :builders],
          into: %{},
          do: {name, Module.concat([__MODULE__, "#{name}#{context.line}"])}

    start_supervised!(
      {FetchView,
       name: names.route_path_view,
       pubsub: Gobusgo.PubSub,
       records: RoutePathBatch.Records,
       id_count_max: 8}
    )

    start_supervised!(
      {StopView,
       name: names.stop_view, pubsub: Gobusgo.PubSub, route_count_max: 8, stop_count_max: 64}
    )

    start_supervised!({RouteScheduleView, name: names.schedule_view, route_count_max: 8})
    start_supervised!({TripPathCache, name: names.cache, trip_count_max: 8})

    start_supervised!(
      {Task.Supervisor,
       name: names.builders, max_children: Map.get(context, :builder_count_max, 2)}
    )

    names
  end

  defp fixture(name) do
    @fixture_directory |> Path.join(name <> ".json") |> File.read!() |> JSON.decode!()
  end

  defp parsed_route_path(request_id) do
    {:ok, route_path} = RoutePaths.parse(fixture("stops_for_route_loop")["data"], @route_id)

    %{
      route_id: @route_id,
      route_path: route_path,
      request_id: request_id,
      fetched_at: @fetched_at,
      data_sha256: String.duplicate("0", 64),
      destination: "raw/oba/stops-for-route/test"
    }
  end

  defp hold_route_path(context, request_id \\ Gobusgo.RequestId.generate()) do
    record = RoutePathBatch.Records.build(parsed_route_path(request_id))
    :ok = FetchView.apply_records(context.route_path_view, [record.value])
  end

  defp hold_stops(context) do
    record = RoutePathBatch.StopRecords.build(parsed_route_path(Gobusgo.RequestId.generate()))
    :ok = StopView.apply_records(context.stop_view, [record.value])
  end

  defp hold_schedule(context) do
    {:ok, schedule} = RouteSchedules.parse(fixture("schedule_for_route_loop")["data"], @route_id)

    record =
      RouteScheduleBatch.Records.build(%{
        route_id: @route_id,
        service_date: @service_date,
        request_id: Gobusgo.RequestId.generate(),
        fetched_at: @fetched_at,
        data_sha256: String.duplicate("0", 64),
        destination: "raw/oba/schedule-for-route/test",
        schedule: schedule
      })

    :ok = RouteScheduleView.apply_records(context.schedule_view, [record.value])
  end

  defp hold_all(context) do
    hold_route_path(context)
    hold_stops(context)
    hold_schedule(context)
  end

  defp request(overrides \\ %{}) do
    Map.merge(
      %{trip_id: @trip_id, route_id: @route_id, service_date_ms: @service_date_ms},
      overrides
    )
  end

  defp fetch(context, requests, options \\ []) do
    TripPaths.fetch(
      requests,
      Keyword.merge(
        [
          route_path_view: context.route_path_view,
          stop_view: context.stop_view,
          schedule_view: context.schedule_view,
          cache: context.cache,
          builders: context.builders
        ],
        options
      )
    )
  end

  defp missing_reason(context, requests) do
    {:ok, %{paths: [], missing: [%{reason: reason}]}} = fetch(context, requests)
    reason
  end

  test "serves the path of a trip the views hold", context do
    hold_all(context)

    {:ok, %{paths: [path], missing: []}} = fetch(context, [request()])

    assert %{trip_id: @trip_id, route_id: @route_id, service_date_ms: @service_date_ms} = path
    assert length(TripPath.decode(path).stop_distances_m) == 8
  end

  test "serves one path for a trip requested twice", context do
    hold_all(context)

    {:ok, %{paths: paths}} = fetch(context, [request(), request()])

    assert length(paths) == 1
  end

  test "holds a path it built in the cache", context do
    hold_all(context)

    {:ok, _served} = fetch(context, [request()])

    assert TripPathCache.count(context.cache) == 1
  end

  test "serves a path the cache holds for the views' current fetches without building it",
       context do
    hold_all(context)
    {:ok, %{paths: [path]}} = fetch(context, [request()])
    held = TripPathCache.lookup(context.cache, {@trip_id, @service_date_ms})
    replaced = %{held | path: %{held.path | points: "held"}}
    :ok = TripPathCache.put(context.cache, [{{@trip_id, @service_date_ms}, replaced}])

    {:ok, %{paths: [served]}} = fetch(context, [request()], builders: NoBuilders)

    assert served == %{path | points: "held"}
  end

  test "builds again a path the cache holds for an earlier fetch of the route path", context do
    hold_all(context)
    {:ok, %{paths: [path]}} = fetch(context, [request()])
    held = TripPathCache.lookup(context.cache, {@trip_id, @service_date_ms})
    replaced = %{held | path: %{held.path | points: "held"}}
    :ok = TripPathCache.put(context.cache, [{{@trip_id, @service_date_ms}, replaced}])

    hold_route_path(context)
    {:ok, %{paths: [served]}} = fetch(context, [request()])

    assert served.points == path.points
  end

  test "names a trip whose route the route path view lacks", context do
    hold_stops(context)
    hold_schedule(context)

    assert missing_reason(context, [request()]) == :route_path_missing
  end

  test "names a trip on a service date the schedule view lacks", context do
    hold_all(context)

    reason = missing_reason(context, [request(%{service_date_ms: @service_date_ms + @day_ms})])

    assert reason == :schedule_missing
  end

  test "names a trip the route's schedule does not list", context do
    hold_all(context)

    assert missing_reason(context, [request(%{trip_id: "1_0"})]) == :schedule_missing
  end

  test "names a trip whose stops the stop view lacks", context do
    hold_route_path(context)
    hold_schedule(context)

    assert missing_reason(context, [request()]) == :stop_positions_missing
  end

  @tag builder_count_max: 0
  test "answers busy when every builder is taken", context do
    hold_all(context)

    assert fetch(context, [request()]) == {:error, :busy}
  end

  test "answers killed, and logs it, when a build outgrows its heap", context do
    hold_all(context)

    log =
      capture_log(fn ->
        assert fetch(context, [request()], heap_words_max: @heap_words_tiny) == {:error, :killed}
      end)

    assert log =~ "Trip paths not built"
  end

  test "answers timeout, and logs it, when a build passes its deadline", context do
    hold_all(context)

    log =
      capture_log(fn ->
        assert fetch(context, [request()], deadline_ms: 0) == {:error, :timeout}
      end)

    assert log =~ "Trip paths not built"
  end

  test "raises for more trips than one request takes", context do
    requests =
      for index <- 1..(TripPaths.request_count_max() + 1), do: request(%{trip_id: "#{index}"})

    assert_raise Gobusgo.Assert.AssertionError, fn -> fetch(context, requests) end
  end
end
