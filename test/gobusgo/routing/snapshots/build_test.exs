defmodule Gobusgo.Routing.Snapshots.BuildTest do
  # Drives run/1 against a schedule view, a stop view, a route view, an
  # agency view, and a snapshots process started for the test, filled with
  # records built from the live schedule fixture and by hand, and a writer
  # double defined here. What a run built is read from the manifest, the
  # destinations and contents written, and the counts.
  use ExUnit.Case, async: true

  alias Gobusgo.Compression
  alias Gobusgo.OneBusAway.AgencyBatch.Records, as: AgencyRecords
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RouteScheduleBatch.Records
  alias Gobusgo.OneBusAway.RouteSchedules
  alias Gobusgo.OneBusAway.RouteScheduleView
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.Routing.Names
  alias Gobusgo.Routing.Snapshots
  alias Gobusgo.Routing.Snapshots.Build

  @moduletag capture_log: true

  defmodule RecordingBackend do
    @behaviour Gobusgo.Writer

    @impl Gobusgo.Writer
    def write(%{destination: destination, content: content}, options) do
      send(Keyword.fetch!(options, :recipient), {:written, destination})
      send(Keyword.fetch!(options, :recipient), {:content, destination, content})
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

    route_view = Module.concat(__MODULE__, "RouteView#{context.line}")
    agency_view = Module.concat(__MODULE__, "AgencyView#{context.line}")

    start_supervised!(
      {FetchView,
       name: route_view, pubsub: Gobusgo.PubSub, records: RouteBatch.Records, id_count_max: 8}
    )

    start_supervised!({AgencyView, name: agency_view, pubsub: Gobusgo.PubSub})
    start_supervised!({Snapshots, name: server})

    %{
      schedule_view: schedule_view,
      stop_view: stop_view,
      route_view: route_view,
      agency_view: agency_view,
      server: server
    }
  end

  # A fetch of agency 19's routes holding route 19_41 in `color`, under a
  # request identifier of its own, so a later fetch replaces an earlier one.
  defp hold_route(context, %{color: color, fetched_at: fetched_at}) do
    record =
      RouteBatch.Records.build(%{
        agency_id: "19",
        destination: "raw/oba/routes-for-agency/test.json.gz",
        fetched_at: fetched_at,
        data_sha256: String.duplicate("ab", 32),
        request_id: Gobusgo.RequestId.generate(),
        routes: [
          %{
            id: "19_41",
            agency_id: "19",
            short_name: "41",
            long_name: nil,
            description: nil,
            type: 3,
            color: color,
            text_color: nil,
            url: nil
          }
        ]
      })

    :ok = FetchView.apply_records(context.route_view, [record.value])
  end

  defp hold_agency(context) do
    %{agencies: agencies, manifest: manifest} =
      AgencyRecords.build(%{
        destination: "raw/oba/agencies-with-coverage/dt=2026-11-07/file.json",
        fetched_at: ~U[2026-11-07 03:15:00Z],
        data_sha256: String.duplicate("ab", 32),
        request_id: "0199c4a2-7e1b-7a3f-9d20-000000000001",
        agencies: [
          %{
            id: "19",
            name: "Intercity Transit",
            url: "https://intercitytransit.example.test",
            timezone: "America/Los_Angeles",
            coverage: %{lat: 47.0, lon: -122.9, lat_span: 0.5, lon_span: 0.5}
          }
        ]
      })

    :ok =
      AgencyView.apply_records(context.agency_view, Enum.map(agencies ++ [manifest], & &1.value))
  end

  # The names the run wrote to the destination `entry` names, which the
  # backend receives as the gzip stream it stores.
  defp written_names(entry) do
    destination = String.trim_leading(entry["files"]["names"]["path"], "/")
    assert_received {:content, ^destination, stream}
    {:ok, content} = Compression.decompress(stream, Compression.content_bytes_max())
    {:ok, names} = Names.decode(content)
    names
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
      route_view: context.route_view,
      agency_view: context.agency_view,
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

  test "names the route view's route and its agency's name in the names file", context do
    hold(context, ~D[2026-11-07])
    hold_route(context, %{color: "005BAA", fetched_at: ~U[2026-11-06 23:00:00Z]})
    hold_agency(context)

    {:ok, _counts} = run(context)
    [entry] = Snapshots.manifest(context.server)["snapshots"]

    assert %{
             "routes" => %{"19_41" => %{"color" => "005BAA", "agencyId" => "19"}},
             "agencyNames" => %{"19" => "Intercity Transit"}
           } = written_names(entry)
  end

  test "names a headsign for every trip of the trips file", context do
    hold(context, ~D[2026-11-07])

    {:ok, _counts} = run(context)
    [entry] = Snapshots.manifest(context.server)["snapshots"]
    headsigns = written_names(entry)["tripHeadsigns"]

    assert {length(headsigns), Enum.all?(headsigns, &is_binary/1)} ==
             {entry["tripCount"], true}
  end

  test "builds a date again when a route's names change", context do
    hold(context, ~D[2026-11-07])
    hold_route(context, %{color: "005BAA", fetched_at: ~U[2026-11-06 23:00:00Z]})
    {:ok, _first} = run(context)
    hold_route(context, %{color: "C00000", fetched_at: ~U[2026-11-07 11:00:00Z]})

    assert {:ok, %{built_count: 1}} = run(context)
  end

  test "passes over a date when a route is fetched again with the same names", context do
    hold(context, ~D[2026-11-07])
    hold_route(context, %{color: "005BAA", fetched_at: ~U[2026-11-06 23:00:00Z]})
    {:ok, _first} = run(context)
    hold_route(context, %{color: "005BAA", fetched_at: ~U[2026-11-07 11:00:00Z]})

    assert {:ok, %{built_count: 0, unchanged_count: 1}} = run(context)
  end

  @tag :tmp_dir
  test "stores the names file as the gzip stream the manifest names", context do
    hold(context, ~D[2026-11-07])

    {:ok, _counts} =
      run(context, write_options: [backend: Gobusgo.Writer.LocalFile, base_dir: context.tmp_dir])

    [entry] = Snapshots.manifest(context.server)["snapshots"]
    %{"path" => path, "byteSize" => byte_size, "sha256" => sha256} = entry["files"]["names"]
    stored = File.read!(Path.join(context.tmp_dir, path))

    assert {byte_size(stored), Base.encode16(:crypto.hash(:sha256, stored), case: :lower)} ==
             {byte_size, sha256}
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
      entry["files"]["transfers"],
      entry["files"]["positions"],
      entry["files"]["names"] | entry["connectionChunks"]
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
