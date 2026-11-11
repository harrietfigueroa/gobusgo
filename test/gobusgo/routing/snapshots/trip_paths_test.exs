defmodule Gobusgo.Routing.Snapshots.TripPathsTest do
  # Drives the trip path files of a date, alone and through a snapshot
  # build, against views started for the test and filled from King County
  # Metro's stored loop route 1_7994 of 2026-11-09, and a writer double
  # defined here. What a build wrote is read from the destinations and
  # contents the double receives and from the manifest.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RoutePathBatch
  alias Gobusgo.OneBusAway.RouteScheduleBatch
  alias Gobusgo.OneBusAway.RouteScheduleView
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.Packed
  alias Gobusgo.Routing.Snapshots
  alias Gobusgo.Routing.Snapshots.Build
  alias Gobusgo.Routing.Snapshots.TripPaths
  alias Gobusgo.Routing.TripPathIndex
  alias Gobusgo.Routing.TripPathShard
  alias Gobusgo.Test.TripPathShardFixture

  @moduletag capture_log: true

  defmodule RecordingBackend do
    @behaviour Gobusgo.Writer

    @impl Gobusgo.Writer
    def write(%{destination: destination, content: content}, options) do
      send(Keyword.fetch!(options, :recipient), {:written, destination, content})
      Keyword.get(options, :result, :ok)
    end
  end

  @service_date ~D[2026-11-09]
  @now ~U[2026-11-09 12:00:00Z]
  @route_id TripPathShardFixture.route_id()
  @directory "routing/snapshots/dt=2026-11-09"
  @heap_words_tiny 1_000

  setup context do
    names =
      for name <- [
            :schedule_view,
            :stop_view,
            :route_path_view,
            :route_view,
            :agency_view,
            :server
          ],
          into: %{},
          do: {name, Module.concat([__MODULE__, "#{name}#{context.line}"])}

    start_supervised!({RouteScheduleView, name: names.schedule_view, route_count_max: 8})

    start_supervised!(
      {StopView,
       name: names.stop_view, pubsub: Gobusgo.PubSub, route_count_max: 8, stop_count_max: 64}
    )

    start_supervised!(
      {FetchView,
       name: names.route_path_view,
       pubsub: Gobusgo.PubSub,
       records: RoutePathBatch.Records,
       id_count_max: 8}
    )

    start_supervised!(
      {FetchView,
       name: names.route_view,
       pubsub: Gobusgo.PubSub,
       records: RouteBatch.Records,
       id_count_max: 8}
    )

    start_supervised!({AgencyView, name: names.agency_view, pubsub: Gobusgo.PubSub})
    start_supervised!({Snapshots, name: names.server})
    names
  end

  defp parsed_route_path(request_id) do
    %{
      route_id: @route_id,
      route_path: TripPathShardFixture.route_path(),
      request_id: request_id,
      fetched_at: ~U[2026-11-09 04:20:32Z],
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
    record =
      RouteScheduleBatch.Records.build(%{
        route_id: @route_id,
        service_date: @service_date,
        request_id: Gobusgo.RequestId.generate(),
        fetched_at: ~U[2026-11-09 04:20:32Z],
        data_sha256: String.duplicate("0", 64),
        destination: "raw/oba/schedule-for-route/test",
        schedule: TripPathShardFixture.parsed_schedule()
      })

    :ok = RouteScheduleView.apply_records(context.schedule_view, [record.value])
  end

  defp hold_all(context) do
    hold_route_path(context)
    hold_stops(context)
    hold_schedule(context)
  end

  defp options(context, overrides \\ []) do
    Keyword.merge(
      [
        schedule_view: context.schedule_view,
        stop_view: context.stop_view,
        route_path_view: context.route_path_view,
        write_options: [backend: RecordingBackend, recipient: self()],
        heap_words_max: TripPaths.heap_words_max()
      ],
      overrides
    )
  end

  defp run(context, overrides \\ []) do
    TripPaths.run(%{
      service_date: @service_date,
      directory: @directory,
      options: options(context, overrides)
    })
  end

  defp build(context, overrides \\ []) do
    defaults = [
      server: context.server,
      schedule_view: context.schedule_view,
      stop_view: context.stop_view,
      route_view: context.route_view,
      agency_view: context.agency_view,
      route_path_view: context.route_path_view,
      clock: fn -> @now end,
      write_options: [backend: RecordingBackend, recipient: self()]
    ]

    Build.run(Keyword.merge(defaults, overrides))
  end

  # The backend receives the gzip stream the writer made of the content of a
  # destination ending in the compression suffix, and any other content as is.
  defp expanded(destination, stored) do
    if Gobusgo.Compression.compressed?(destination) do
      {:ok, content} = Packed.expand(stored, Gobusgo.Compression.content_bytes_max())
      content
    else
      stored
    end
  end

  # The destinations and expanded contents written, in order.
  defp writes(writes \\ []) do
    receive do
      {:written, destination, stored} ->
        writes([{destination, expanded(destination, stored)} | writes])
    after
      0 -> Enum.reverse(writes)
    end
  end

  defp entry(context) do
    [entry] = Snapshots.manifest(context.server)["snapshots"]
    entry
  end

  describe "run/1" do
    test "writes one shard of the route and an index that names it, shard first", context do
      hold_all(context)

      assert {:built, %{index_entry: index_entry, shard_count: 1, trip_path_count: 2}} =
               run(context)

      assert [
               {"routing/snapshots/dt=2026-11-09/trip-paths-" <> _shard, _shard_content},
               {"routing/snapshots/dt=2026-11-09/trip-paths-index-" <> _index, index_content}
             ] = writes()

      {:ok, [%{route_id: @route_id, path: path}]} = TripPathIndex.decode(index_content)
      assert path =~ ~r"^/routing/snapshots/dt=2026-11-09/trip-paths-[0-9a-f]{64}\.bin\.gz$"
      assert index_entry["path"] =~ "trip-paths-index-"
    end

    test "names the shard by the SHA-256 and byte size of its gzip stream", context do
      hold_all(context)
      {:built, _built} = run(context)
      [{_shard_destination, shard_content}, {_index_destination, index_content}] = writes()
      stored = Packed.stored(shard_content)

      assert {:ok, [%{path: path, byte_size: byte_size, sha256: sha256}]} =
               TripPathIndex.decode(index_content)

      assert {path, byte_size, sha256} ==
               {"/" <> Packed.destination(%{directory: @directory, kind: 1, stored: stored}),
                stored.byte_size, stored.sha256}
    end

    test "writes a shard that decodes to the trips of the route", context do
      hold_all(context)
      {:built, _built} = run(context)
      [{_destination, shard_content} | _index] = writes()

      assert {:ok, [%{id: "1_1137791"}, %{id: "1_1137792"}]} =
               TripPathShard.decode(shard_content)
    end

    test "builds nothing for a route the route path view has no path of", context do
      hold_stops(context)
      hold_schedule(context)

      assert {:built, %{index_entry: nil, shard_count: 0, trip_path_count: 0}} = run(context)
      assert writes() == []
    end

    test "builds nothing for a route none of whose stops has a position", context do
      hold_route_path(context)
      hold_schedule(context)

      assert {:built, %{index_entry: nil, shard_count: 0}} = run(context)
      assert writes() == []
    end

    test "is killed when its heap outgrows the cap, with nothing written", context do
      hold_all(context)

      assert :killed == run(context, heap_words_max: @heap_words_tiny)
      assert writes() == []
    end

    test "fails when a shard is not written", context do
      hold_all(context)

      write_options = [
        backend: RecordingBackend,
        recipient: self(),
        result: {:error, :io_failure}
      ]

      assert :failed == run(context, write_options: write_options)
    end

    test "counts a file that already exists as written", context do
      hold_all(context)

      write_options = [
        backend: RecordingBackend,
        recipient: self(),
        result: {:error, :already_exists}
      ]

      assert {:built, %{shard_count: 1}} = run(context, write_options: write_options)
    end
  end

  describe "Build.run/1" do
    test "names the index of the date's shards as files.tripPaths", context do
      hold_all(context)

      assert {:ok, %{trip_path_count: 2, trip_path_shard_count: 1, trip_path_failed_count: 0}} =
               build(context)

      assert %{"files" => %{"tripPaths" => %{"path" => path, "byteSize" => _, "sha256" => _}}} =
               entry(context)

      assert path =~ ~r"^/routing/snapshots/dt=2026-11-09/trip-paths-index-[0-9a-f]{64}\.bin\.gz$"
    end

    test "writes the shards and the index before the entry names them", context do
      hold_all(context)
      {:ok, _counts} = build(context)
      named = entry(context)["files"]["tripPaths"]["path"]

      destinations = Enum.map(writes(), &elem(&1, 0))

      assert String.trim_leading(named, "/") in destinations
    end

    test "records the entry with no tripPaths for a date with no route path", context do
      hold_stops(context)
      hold_schedule(context)

      assert {:ok, %{trip_path_shard_count: 0, trip_path_failed_count: 0}} = build(context)
      refute Map.has_key?(entry(context)["files"], "tripPaths")
    end

    test "records the entry with no tripPaths when the trip path build is killed", context do
      hold_all(context)

      assert {:ok, %{built_count: 1, trip_path_failed_count: 1, trip_path_shard_count: 0}} =
               build(context, trip_path_heap_words_max: @heap_words_tiny)

      refute Map.has_key?(entry(context)["files"], "tripPaths")
      assert Map.has_key?(entry(context)["files"], "names")
    end

    test "builds a date again when its route path is fetched again", context do
      hold_all(context)
      {:ok, _first} = build(context)
      hold_route_path(context)

      assert {:ok, %{built_count: 1, unchanged_count: 0}} = build(context)
    end

    test "passes over a date whose inputs, route paths included, are unchanged", context do
      hold_all(context)
      {:ok, _first} = build(context)

      assert {:ok, %{built_count: 0, unchanged_count: 1}} = build(context)
    end

    test "builds a date again once its route path arrives", context do
      hold_stops(context)
      hold_schedule(context)
      {:ok, _first} = build(context)
      hold_route_path(context)

      assert {:ok, %{built_count: 1, trip_path_shard_count: 1}} = build(context)
      assert Map.has_key?(entry(context)["files"], "tripPaths")
    end
  end
end
