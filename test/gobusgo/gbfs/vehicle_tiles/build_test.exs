defmodule Gobusgo.Gbfs.VehicleTiles.BuildTest do
  # Drives run/2 against a shared vehicle view, a vehicle type view, and a
  # tile process started for the test, the views fed records built here,
  # and writes through the local file writer under a temporary directory or
  # through a writer double defined here. What a run published is read from
  # the tile process and from the files the directory holds.
  use ExUnit.Case, async: true

  alias Gobusgo.Gbfs.VehicleStatusBatch.Records
  alias Gobusgo.Gbfs.VehicleStatusView
  alias Gobusgo.Gbfs.VehicleTiles
  alias Gobusgo.Gbfs.VehicleTiles.Build
  alias Gobusgo.Gbfs.VehicleTileSet
  alias Gobusgo.Gbfs.VehicleTypeRecords
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.RequestId

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @system_id "lime_seattle"

  defmodule FailingBackend do
    @behaviour Gobusgo.Writer

    @impl Gobusgo.Writer
    def write(_request, _options), do: {:error, :io_failure}
  end

  setup context do
    view = Module.concat(__MODULE__, "View#{context.line}")
    type_view = Module.concat(__MODULE__, "TypeView#{context.line}")
    server = Module.concat(__MODULE__, "Tiles#{context.line}")

    start_supervised!(
      {VehicleStatusView, name: view, pubsub: Gobusgo.PubSub, system_count_max: 8}
    )

    start_supervised!(
      {FetchView,
       name: type_view, pubsub: Gobusgo.PubSub, records: VehicleTypeRecords, id_count_max: 8}
    )

    start_supervised!({VehicleTiles, name: server, pubsub: Gobusgo.PubSub})
    %{view: view, type_view: type_view, server: server}
  end

  defp vehicle(lat, lon) do
    %{
      id: "bike-#{System.unique_integer([:positive])}",
      position: %{lat: lat, lon: lon},
      vehicle_type_id: "2",
      current_range_meters: 12_000,
      is_disabled: false,
      is_reserved: false,
      last_reported: nil
    }
  end

  defp hold_fetch(context, fetched_at) do
    record =
      Records.build_fetched(%{
        kind: :fetched,
        id: @system_id,
        version: "2.2",
        last_updated: fetched_at,
        ttl: 60,
        vehicles: [vehicle(47.6114, -122.337), vehicle(47.6614, -122.313)],
        data_sha256: String.duplicate("0", 64),
        destination: "raw/gbfs/free-bike-status/test",
        fetched_at: fetched_at,
        request_id: RequestId.generate()
      })

    :ok = VehicleStatusView.apply_records(context.view, [record.value])
  end

  defp hold_not_published(context) do
    record =
      Records.build_not_published(%{
        kind: :not_published,
        id: @system_id,
        fetched_at: ~U[2026-11-08 19:10:00Z],
        request_id: RequestId.generate()
      })

    :ok = VehicleStatusView.apply_records(context.view, [record.value])
  end

  defp run(context, write_options) do
    Build.run(@system_id,
      server: context.server,
      view: context.view,
      type_view: context.type_view,
      write_options: write_options
    )
  end

  defp stored?(tmp_dir, destination) do
    match?({:ok, _content}, Gobusgo.Reader.read(destination, base_dir: tmp_dir))
  end

  test "makes the fetch's index current", %{tmp_dir: tmp_dir} = context do
    hold_fetch(context, ~U[2026-11-08 19:08:30Z])

    {:ok, %{kind: :published, index: index}} = run(context, base_dir: tmp_dir)

    assert VehicleTiles.current(context.server) == [index]
  end

  test "stores every file the index names", %{tmp_dir: tmp_dir} = context do
    hold_fetch(context, ~U[2026-11-08 19:08:30Z])

    {:ok, %{index: %{destination: destination}}} = run(context, base_dir: tmp_dir)

    {:ok, content} = Gobusgo.Reader.read(destination, base_dir: tmp_dir)
    index = JSON.decode!(content)
    directory = Path.dirname(destination)

    tile_names =
      for [x, y, _count, hash] <- index["tiles"], do: "tile-14-#{x}-#{y}-#{hash}.bin.gz"

    for name <- [index["city"] | tile_names] do
      assert stored?(tmp_dir, directory <> "/" <> name)
    end
  end

  test "stores files whose fetch the retention reads", %{tmp_dir: tmp_dir} = context do
    hold_fetch(context, ~U[2026-11-08 19:08:30Z])

    {:ok, %{index: %{destination: destination}}} = run(context, base_dir: tmp_dir)

    assert {:ok, %{fetched_at: ~U[2026-11-08 19:08:30Z]}} =
             VehicleTileSet.parse_destination(destination)
  end

  test "announces the new index", %{tmp_dir: tmp_dir} = context do
    :ok = VehicleTiles.subscribe(%{server: context.server, pubsub: Gobusgo.PubSub})
    hold_fetch(context, ~U[2026-11-08 19:08:30Z])

    {:ok, _published} = run(context, base_dir: tmp_dir)

    server = context.server
    assert_receive {:vehicle_tiles_switched, ^server}
  end

  test "keeps the index current before when a file is not written",
       %{tmp_dir: tmp_dir} = context do
    hold_fetch(context, ~U[2026-11-08 19:08:30Z])
    {:ok, %{index: before}} = run(context, base_dir: tmp_dir)
    hold_fetch(context, ~U[2026-11-08 19:09:30Z])

    assert {:error, %{failed_count: 3}} = run(context, backend: FailingBackend)
    assert VehicleTiles.current(context.server) == [before]
  end

  test "drops the index of a feed that is not published", %{tmp_dir: tmp_dir} = context do
    hold_fetch(context, ~U[2026-11-08 19:08:30Z])
    {:ok, _published} = run(context, base_dir: tmp_dir)
    hold_not_published(context)

    assert {:ok, %{kind: :cleared}} = run(context, base_dir: tmp_dir)
    assert VehicleTiles.current(context.server) == []
  end

  test "passes over an index older than the current one", context do
    newer = %{
      system_id: @system_id,
      destination: "shared-vehicles/newer",
      fetched_at: ~U[2026-11-08 19:09:30Z],
      vehicle_count: 2
    }

    older = %{newer | destination: "shared-vehicles/older", fetched_at: ~U[2026-11-08 19:08:30Z]}
    :ok = VehicleTiles.record(context.server, newer)
    :ok = VehicleTiles.record(context.server, older)

    assert VehicleTiles.current(context.server) == [newer]
  end
end
