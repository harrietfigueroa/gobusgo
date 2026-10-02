defmodule Gobusgo.OneBusAway.VehicleViewInProcessTest do
  # Publishes the records of one fetch through the publisher the application
  # configures and reads the application's vehicle view back. Each test
  # restarts that view, which is global state, hence the non-async case.
  use ExUnit.Case, async: false

  alias Gobusgo.OneBusAway.VehicleBatch.Records
  alias Gobusgo.OneBusAway.VehicleView
  alias Gobusgo.Publisher

  @moduletag capture_log: true

  setup do
    restart_view()
    on_exit(&restart_view/0)
  end

  defp restart_view do
    :ok = Supervisor.terminate_child(Gobusgo.Supervisor, VehicleView)
    {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, VehicleView)
  end

  test "records published to the vehicle state topic become the view's current fetch" do
    %{vehicles: vehicles, manifest: manifest} =
      Records.build(%{
        agency_id: "1",
        destination: "raw/oba/vehicles-for-agency/agency=1/dt=2026-10-02/file.json",
        fetched_at: ~U[2026-10-02 03:15:00Z],
        data_sha256: String.duplicate("ab", 32),
        request_id: "0199c4a2-7e1b-7a3f-9d20-000000000001",
        vehicles: [
          %{
            id: "1_4207",
            active_trip_id: nil,
            position: nil,
            orientation: nil,
            last_known_location: nil,
            last_known_orientation: nil,
            last_update_time_ms: nil,
            last_location_update_time_ms: nil,
            predicted: nil
          }
        ]
      })

    assert Publisher.publish(vehicles ++ [manifest], []) == :ok

    assert [%{agency_id: "1", vehicle_ids: ["1_4207"]}] = VehicleView.current(VehicleView)
  end
end
