defmodule Gobusgo.Routing.Snapshots.BuildWalkTest do
  # Drives run/1 with each walk basis against the views and a snapshots
  # process started for the test, with the walk graph fixture published into
  # the test's temporary directory: what the manifest entry says of how its
  # walks were measured, what a run does when the streets are not available,
  # and that the straight line reads no walk graph at all.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RouteScheduleBatch.Records
  alias Gobusgo.OneBusAway.RouteSchedules
  alias Gobusgo.OneBusAway.RouteScheduleView
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.Reader
  alias Gobusgo.Routing.Snapshots
  alias Gobusgo.Routing.Snapshots.Build
  alias Gobusgo.Test.WalkGraphFixture
  alias Gobusgo.WalkGraph.Publication
  alias Gobusgo.Writer

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @fixture_path Path.expand("../../../fixtures/one_bus_away/schedule_for_route.json", __DIR__)
  @now ~U[2026-11-07 12:00:00Z]
  @settle_attempts_max 200
  @settle_pause_ms 25

  defmodule RecordingBackend do
    @behaviour Gobusgo.Writer

    @impl Gobusgo.Writer
    def write(%{destination: destination}, options) do
      send(Keyword.fetch!(options, :recipient), {:written, destination})
      :ok
    end
  end

  defmodule UnreadableReader do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(_destination, options), do: reached(options)

    @impl Gobusgo.Reader
    def discover(_request, options), do: reached(options)

    defp reached(options) do
      send(Keyword.fetch!(options, :recipient), :walk_graph_read)
      {:error, :io_failure}
    end
  end

  setup context do
    names =
      for name <- [:schedule_view, :stop_view, :route_view, :agency_view, :server],
          into: %{},
          do: {name, Module.concat([__MODULE__, "#{name}#{context.line}"])}

    start_supervised!({RouteScheduleView, name: names.schedule_view, route_count_max: 8})

    start_supervised!(
      {StopView,
       name: names.stop_view, pubsub: Gobusgo.PubSub, route_count_max: 8, stop_count_max: 8}
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
    hold(names, ~D[2026-11-07])
    Map.put(names, :tmp_dir, context.tmp_dir)
  end

  defp hold(names, service_date) do
    data = @fixture_path |> File.read!() |> JSON.decode!() |> Map.fetch!("data")

    start_ms =
      DateTime.to_unix(DateTime.new!(service_date, ~T[08:00:00], "Etc/UTC"), :millisecond)

    {:ok, schedule} =
      RouteSchedules.parse(put_in(data, ["entry", "scheduleDate"], start_ms), "19_41")

    record =
      Records.build(%{
        route_id: "19_41",
        service_date: service_date,
        request_id: Gobusgo.RequestId.generate(),
        fetched_at: ~U[2026-11-06 23:15:00Z],
        data_sha256: String.duplicate("0", 64),
        destination: "raw/oba/schedule-for-route/test",
        schedule: schedule
      })

    :ok = RouteScheduleView.apply_records(names.schedule_view, [record.value])
  end

  defp read_options(context), do: [backend: Reader.LocalFile, base_dir: context.tmp_dir]

  defp publish_graph(context) do
    packed = fn pieces ->
      for %{class: class, points: points} <- pieces do
        {class, for({lat, lon} <- points, into: <<>>, do: <<lat::signed-32, lon::signed-32>>)}
      end
    end

    {:ok, _published} =
      Publication.publish(
        %{
          built_at: ~U[2026-11-14 12:00:00Z],
          source_date: "2026-11-08T21:21:00Z",
          tiles: %{
            {4761, -8156} => packed.(WalkGraphFixture.pieces(:west)),
            {4761, -8155} => packed.(WalkGraphFixture.pieces(:east))
          }
        },
        read_options: read_options(context),
        write_options: [backend: Writer.LocalFile, base_dir: context.tmp_dir],
        delete_options: [backend: Gobusgo.Deleter.LocalFile, base_dir: context.tmp_dir]
      )

    :ok
  end

  defp run(context, options) do
    defaults = [
      server: context.server,
      schedule_view: context.schedule_view,
      stop_view: context.stop_view,
      route_view: context.route_view,
      agency_view: context.agency_view,
      clock: fn -> @now end,
      write_options: [backend: RecordingBackend, recipient: self()],
      walk_read_options: read_options(context)
    ]

    Build.run(Keyword.merge(defaults, options))
  end

  defp rules(context) do
    [entry] = Snapshots.manifest(context.server)["snapshots"]
    entry["transferRules"]
  end

  # Runs until the entry says the streets, or fails the test.
  defp run_until_streets(context) do
    Enum.find_value(1..@settle_attempts_max, fn _attempt ->
      {:ok, _counts} = run(context, walk_basis: :streets)

      case rules(context) do
        %{"walkBasis" => "streets"} = rules ->
          rules

        _straight ->
          Process.sleep(@settle_pause_ms)
          nil
      end
    end)
  end

  test "names the straight line in the entry when it is configured", context do
    {:ok, %{built_count: 1}} = run(context, walk_basis: :straight)

    assert %{"walkBasis" => "straight", "walkRadiusM" => 400} = rules = rules(context)
    refute Map.has_key?(rules, "walkStreetMetersMax")
    refute Map.has_key?(rules, "walkGraphBuildId")
  end

  test "reads no walk graph and starts no measuring with the straight line", context do
    {:ok, _counts} =
      run(context,
        walk_basis: :straight,
        walk_read_options: [backend: UnreadableReader, recipient: self()]
      )

    refute_received :walk_graph_read
  end

  test "builds by the straight line when the streets are configured and no graph is published",
       context do
    assert {:ok, %{built_count: 1}} = run(context, walk_basis: :streets)

    assert %{"walkBasis" => "straight"} = rules(context)
  end

  test "builds a date again when the basis changes", context do
    {:ok, %{built_count: 1}} = run(context, walk_basis: :straight)

    assert {:ok, %{built_count: 1, unchanged_count: 0}} = run(context, walk_basis: :streets)
    assert {:ok, %{built_count: 0, unchanged_count: 1}} = run(context, walk_basis: :streets)
  end

  test "builds by the straight line at first and by the streets once they are measured",
       context do
    publish_graph(context)
    {:ok, %{built_count: 1}} = run(context, walk_basis: :streets)
    assert %{"walkBasis" => "straight"} = rules(context)

    assert %{
             "walkBasis" => "streets",
             "walkStreetMetersMax" => 600,
             "walkGraphBuildId" => build_id,
             "walkRadiusM" => 400
           } = run_until_streets(context)

    assert build_id =~ ~r/\A[0-9a-f]{16}\z/
  end

  test "keeps the entries there are when the walk graph cannot be read", context do
    {:ok, %{built_count: 1}} = run(context, walk_basis: :straight)
    [before_run] = Snapshots.manifest(context.server)["snapshots"]

    assert {:ok, %{built_count: 0, unchanged_count: 1}} =
             run(context,
               walk_basis: :streets,
               walk_read_options: [backend: UnreadableReader, recipient: self()]
             )

    assert_received :walk_graph_read
    assert Snapshots.manifest(context.server)["snapshots"] == [before_run]
  end

  test "builds a date with no entry by the straight line when the walk graph cannot be read",
       context do
    assert {:ok, %{built_count: 1}} =
             run(context,
               walk_basis: :streets,
               walk_read_options: [backend: UnreadableReader, recipient: self()]
             )

    assert %{"walkBasis" => "straight"} = rules(context)
  end
end
