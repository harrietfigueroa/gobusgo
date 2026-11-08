defmodule Gobusgo.Gbfs.VehicleStatusViewTest do
  # Starts a view per test, hands it records built by the records module for
  # fetches the test names, and reads what the view then holds.
  use ExUnit.Case, async: true

  alias Gobusgo.Gbfs.VehicleStatusBatch.Records
  alias Gobusgo.Gbfs.VehicleStatusView

  @moduletag capture_log: true

  @vehicle %{
    id: "c7629d49",
    position: %{lat: 47.639769, lon: -122.403769},
    vehicle_type_id: "8",
    current_range_meters: 34_247,
    is_disabled: false,
    is_reserved: false,
    last_reported: ~U[2026-11-08 19:07:55Z]
  }

  setup context do
    view = Module.concat(__MODULE__, "View#{context.line}")

    start_supervised!(
      {VehicleStatusView, name: view, pubsub: Gobusgo.PubSub, system_count_max: 1}
    )

    %{view: view}
  end

  defp fetched(fetched_at, vehicles) do
    Records.build_fetched(%{
      kind: :fetched,
      id: "lime_seattle",
      version: "3.0",
      last_updated: fetched_at,
      ttl: 60,
      vehicles: vehicles,
      data_sha256: String.duplicate("a", 64),
      destination: "raw/gbfs/free-bike-status/example.json.gz",
      fetched_at: fetched_at,
      request_id: Gobusgo.RequestId.generate()
    }).value
  end

  defp not_published(checked_at) do
    Records.build_not_published(%{
      kind: :not_published,
      id: "lime_seattle",
      fetched_at: checked_at,
      request_id: Gobusgo.RequestId.generate()
    }).value
  end

  test "starts empty", %{view: view} do
    assert VehicleStatusView.current(view, "lime_seattle") == nil
    assert VehicleStatusView.vehicles(view, "lime_seattle") == []
  end

  test "holds a fetch's vehicles as the processor published them", %{view: view} do
    :ok = VehicleStatusView.apply_records(view, [fetched(~U[2026-11-08 19:08:00Z], [@vehicle])])

    assert VehicleStatusView.vehicles(view, "lime_seattle") == [@vehicle]
  end

  test "replaces a fetch with a newer one whole", %{view: view} do
    newer_vehicle = %{@vehicle | id: "2f255d4f", position: nil, last_reported: nil}
    :ok = VehicleStatusView.apply_records(view, [fetched(~U[2026-11-08 19:08:00Z], [@vehicle])])

    :ok =
      VehicleStatusView.apply_records(view, [fetched(~U[2026-11-08 19:09:00Z], [newer_vehicle])])

    assert VehicleStatusView.vehicles(view, "lime_seattle") == [newer_vehicle]
  end

  test "empties with a newer fetch of no vehicles", %{view: view} do
    :ok = VehicleStatusView.apply_records(view, [fetched(~U[2026-11-08 19:08:00Z], [@vehicle])])
    :ok = VehicleStatusView.apply_records(view, [fetched(~U[2026-11-08 19:09:00Z], [])])

    assert VehicleStatusView.vehicles(view, "lime_seattle") == []
  end

  test "keeps a fetch over an older one", %{view: view} do
    :ok = VehicleStatusView.apply_records(view, [fetched(~U[2026-11-08 19:09:00Z], [@vehicle])])
    :ok = VehicleStatusView.apply_records(view, [fetched(~U[2026-11-08 19:08:00Z], [])])

    assert VehicleStatusView.vehicles(view, "lime_seattle") == [@vehicle]
  end

  test "holds no vehicle once the feed is found not published", %{view: view} do
    :ok = VehicleStatusView.apply_records(view, [fetched(~U[2026-11-08 19:08:00Z], [@vehicle])])
    :ok = VehicleStatusView.apply_records(view, [not_published(~U[2026-11-08 19:09:00Z])])

    assert VehicleStatusView.vehicles(view, "lime_seattle") == []
  end

  test "announces a switch to its subscribers", %{view: view} do
    VehicleStatusView.subscribe(%{view: view, pubsub: Gobusgo.PubSub})
    :ok = VehicleStatusView.apply_records(view, [fetched(~U[2026-11-08 19:08:00Z], [])])

    assert_receive {:vehicle_status_view_switched, ^view}
  end

  test "skips a value that is not a record", %{view: view} do
    :ok = VehicleStatusView.apply_records(view, ["not a record"])

    assert VehicleStatusView.current(view, "lime_seattle") == nil
  end
end
