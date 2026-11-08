defmodule Gobusgo.Routing.Snapshots.BuildTest do
  # Drives run/1 against a schedule view, a stop view, and a snapshots
  # process started for the test, filled with records built from the live
  # schedule fixture, and a writer double defined here. What a run built is
  # read from the manifest, the destinations written, and the counts.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.RouteScheduleBatch.Records
  alias Gobusgo.OneBusAway.RouteSchedules
  alias Gobusgo.OneBusAway.RouteScheduleView
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.Routing.Snapshots
  alias Gobusgo.Routing.Snapshots.Build

  @moduletag capture_log: true

  defmodule RecordingBackend do
    @behaviour Gobusgo.Writer

    @impl Gobusgo.Writer
    def write(%{destination: destination}, options) do
      send(Keyword.fetch!(options, :recipient), {:written, destination})
      Keyword.get(options, :result, :ok)
    end
  end

  @fixture_path Path.expand("../../../fixtures/one_bus_away/schedule_for_route.json", __DIR__)
  @now ~U[2026-11-07 12:00:00Z]

  setup context do
    schedule_view = Module.concat(__MODULE__, "ScheduleView#{context.line}")
    stop_view = Module.concat(__MODULE__, "StopView#{context.line}")
    server = Module.concat(__MODULE__, "Snapshots#{context.line}")
    start_supervised!({RouteScheduleView, name: schedule_view, route_count_max: 8})

    start_supervised!(
      {StopView, name: stop_view, pubsub: Gobusgo.PubSub, route_count_max: 8, stop_count_max: 8}
    )

    start_supervised!({Snapshots, name: server})
    %{schedule_view: schedule_view, stop_view: stop_view, server: server}
  end

  defp hold(context, service_date) do
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

    :ok = RouteScheduleView.apply_records(context.schedule_view, [record.value])
  end

  defp run(context, options \\ []) do
    defaults = [
      server: context.server,
      schedule_view: context.schedule_view,
      stop_view: context.stop_view,
      clock: fn -> @now end,
      write_options: [backend: RecordingBackend, recipient: self()]
    ]

    Build.run(Keyword.merge(defaults, options))
  end

  defp written(destinations \\ []) do
    receive do
      {:written, destination} -> written([destination | destinations])
    after
      0 -> Enum.reverse(destinations)
    end
  end

  test "builds one snapshot per held service date and names it in the manifest", context do
    hold(context, ~D[2026-11-07])
    hold(context, ~D[2026-11-08])

    assert {:ok, %{built_count: 2, unchanged_count: 0}} = run(context)

    assert [
             %{"serviceDate" => "2026-11-07", "previousServiceDateIncluded" => false},
             %{"serviceDate" => "2026-11-08", "previousServiceDateIncluded" => true}
           ] = Snapshots.manifest(context.server)["snapshots"]
  end

  test "writes every file the manifest names before naming it", context do
    hold(context, ~D[2026-11-07])

    {:ok, _counts} = run(context)
    [entry] = Snapshots.manifest(context.server)["snapshots"]

    named = [
      entry["files"]["stops"],
      entry["files"]["trips"],
      entry["files"]["transfers"] | entry["connectionChunks"]
    ]

    assert Enum.sort(written()) ==
             Enum.sort(Enum.map(named, &String.trim_leading(&1["path"], "/")))
  end

  test "passes over a date whose inputs are unchanged since a build today", context do
    hold(context, ~D[2026-11-07])
    {:ok, _first} = run(context)
    _first_files = written()

    assert {:ok, %{built_count: 0, unchanged_count: 1}} = run(context)
    assert written() == []
  end

  test "builds a date again on a later day, under that day", context do
    hold(context, ~D[2026-11-07])
    {:ok, _first} = run(context)
    _first_files = written()

    assert {:ok, %{built_count: 1}} = run(context, clock: fn -> ~U[2026-11-08 00:10:00Z] end)
    assert Enum.all?(written(), &String.starts_with?(&1, "routing/snapshots/dt=2026-11-08/"))
  end

  test "counts a file that already exists as written", context do
    hold(context, ~D[2026-11-07])

    options = [
      write_options: [
        backend: RecordingBackend,
        recipient: self(),
        result: {:error, :already_exists}
      ]
    ]

    assert {:ok, %{built_count: 1}} = run(context, options)
  end

  test "keeps no entry for a date whose files were not written", context do
    hold(context, ~D[2026-11-07])

    options = [
      write_options: [backend: RecordingBackend, recipient: self(), result: {:error, :io_failure}]
    ]

    assert {:error, %{failed_count: 1}} = run(context, options)
    assert Snapshots.manifest(context.server)["snapshots"] == []
  end

  test "drops the entry of a date the view no longer holds", context do
    for day <- 6..8, do: hold(context, Date.new!(2026, 11, day))
    {:ok, _first} = run(context)
    hold(context, ~D[2026-11-09])

    {:ok, _second} = run(context)

    assert Enum.map(Snapshots.manifest(context.server)["snapshots"], & &1["serviceDate"]) ==
             ["2026-11-07", "2026-11-08", "2026-11-09"]
  end
end
