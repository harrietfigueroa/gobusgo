defmodule Gobusgo.OneBusAway.VehicleViewTest do
  # Starts a view of its own per test and feeds it the record values
  # VehicleBatch.Records builds, then reads the view back the way a request
  # does. Announcements travel over the application's publish-subscribe
  # server, on a topic of the test's own view.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.OneBusAway.VehicleBatch.Records
  alias Gobusgo.OneBusAway.VehicleView

  @moduletag capture_log: true

  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"

  setup context do
    view = Module.concat(__MODULE__, "View#{context.line}")
    start_supervised!({VehicleView, name: view, pubsub: Gobusgo.PubSub})
    %{view: view}
  end

  defp vehicle(id) do
    %{
      id: id,
      active_trip_id: nil,
      position: %{lat: 47.66, lon: -122.34},
      orientation: nil,
      last_known_location: nil,
      last_known_orientation: nil,
      last_update_time_ms: nil,
      last_location_update_time_ms: 0,
      predicted: false
    }
  end

  defp records(ids, overrides \\ %{}) do
    Records.build(
      Map.merge(
        %{
          agency_id: "1",
          destination: "raw/oba/vehicles-for-agency/agency=1/dt=2026-10-02/file.json",
          fetched_at: ~U[2026-10-02 03:15:00Z],
          data_sha256: String.duplicate("ab", 32),
          request_id: @request_id,
          vehicles: Enum.map(ids, &vehicle/1)
        },
        overrides
      )
    )
  end

  defp values(%{vehicles: vehicles, manifest: manifest}) do
    Enum.map(vehicles ++ [manifest], & &1.value)
  end

  describe "current/1" do
    test "is empty before a fetch is complete", %{view: view} do
      assert VehicleView.current(view) == []
    end

    test "is empty for a view that is not running" do
      assert VehicleView.current(Gobusgo.OneBusAway.VehicleViewTest.NotStarted) == []
    end

    test "is the fetch whose vehicles and manifest were applied", %{view: view} do
      assert VehicleView.apply_records(view, values(records(["1_b", "1_a"]))) == :ok

      assert [
               %{
                 agency_id: "1",
                 request_id: @request_id,
                 fetched_at: ~U[2026-10-02 03:15:00Z],
                 vehicle_ids: ["1_a", "1_b"],
                 vehicles: %{
                   "1_a" => %{"position" => %{"lat" => 47.66, "lon" => -122.34}},
                   "1_b" => %{"lastLocationUpdateTimeMs" => 0}
                 }
               }
             ] = VehicleView.current(view)
    end

    test "holds the current fetch of every agency, in agency identifier order", %{view: view} do
      other =
        records(["40_x"], %{
          agency_id: "40",
          request_id: "0199c4a2-7e1b-7a3f-9d20-000000000040"
        })

      :ok = VehicleView.apply_records(view, values(other))
      :ok = VehicleView.apply_records(view, values(records(["1_a"])))

      assert Enum.map(VehicleView.current(view), &{&1.agency_id, &1.vehicle_ids}) ==
               [{"1", ["1_a"]}, {"40", ["40_x"]}]
    end
  end

  describe "expired_vehicle_ids/2" do
    @later %{
      fetched_at: ~U[2026-10-02 03:20:01Z],
      request_id: "0199c4a2-7e1b-7a3f-9d20-000000000002"
    }

    test "names the vehicles last seen before the grace period of a fetch without them",
         %{view: view} do
      :ok = VehicleView.apply_records(view, values(records(["1_a", "1_b"])))

      fetch = %{agency_id: "1", fetched_at: @later.fetched_at, vehicle_ids: ["1_a"]}

      assert VehicleView.expired_vehicle_ids(view, fetch) == ["1_b"]
    end

    test "names no vehicle within the grace period", %{view: view} do
      :ok = VehicleView.apply_records(view, values(records(["1_a", "1_b"])))

      fetch = %{agency_id: "1", fetched_at: ~U[2026-10-02 03:20:00Z], vehicle_ids: []}

      assert VehicleView.expired_vehicle_ids(view, fetch) == []
    end

    test "names an expired vehicle once: the switch to the later fetch forgets it",
         %{view: view} do
      :ok = VehicleView.apply_records(view, values(records(["1_a", "1_b"])))
      :ok = VehicleView.apply_records(view, values(records(["1_a"], @later)))

      fetch = %{
        agency_id: "1",
        fetched_at: DateTime.add(@later.fetched_at, 5, :second),
        vehicle_ids: ["1_a"]
      }

      assert VehicleView.expired_vehicle_ids(view, fetch) == []
    end

    test "is empty for an agency the view has seen no vehicle of", %{view: view} do
      fetch = %{agency_id: "40", fetched_at: @later.fetched_at, vehicle_ids: []}

      assert VehicleView.expired_vehicle_ids(view, fetch) == []
    end

    test "is empty for a view that is not running" do
      fetch = %{agency_id: "1", fetched_at: @later.fetched_at, vehicle_ids: []}

      assert VehicleView.expired_vehicle_ids(__MODULE__.NotStarted, fetch) == []
    end
  end

  describe "apply_records/2" do
    test "keeps a fetch invisible until its manifest is applied", %{view: view} do
      %{vehicles: vehicles, manifest: manifest} = records(["1_a", "1_b"])

      assert VehicleView.apply_records(view, Enum.map(vehicles, & &1.value)) == :ok
      assert VehicleView.current(view) == []

      assert VehicleView.apply_records(view, [manifest.value]) == :ok
      assert [%{vehicle_ids: ["1_a", "1_b"]}] = VehicleView.current(view)
    end

    test "keeps the agency's current fetch when an older one is applied", %{view: view} do
      :ok = VehicleView.apply_records(view, values(records(["1_a", "1_b"])))

      older =
        records(["1_a"], %{
          fetched_at: ~U[2026-10-02 03:14:00Z],
          request_id: "0199c4a2-7e1b-7a3f-9d20-000000000000"
        })

      assert VehicleView.apply_records(view, values(older)) == :ok
      assert [%{request_id: @request_id}] = VehicleView.current(view)
    end

    test "skips a value that is not a record and applies the rest", %{view: view} do
      assert VehicleView.apply_records(view, ["{not json" | values(records(["1_a"]))]) == :ok
      assert [%{vehicle_ids: ["1_a"]}] = VehicleView.current(view)
    end

    test "logs a switch once at info", %{view: view} do
      log =
        capture_log([metadata: :all], fn ->
          VehicleView.apply_records(view, values(records(["1_a", "1_b"])))
        end)

      assert log =~ "[info]"
      assert log =~ "Vehicle view switched"
      assert log =~ "agency_count=1"
      assert log =~ "vehicle_count=2"
    end

    test "logs skipped values once at warning with their count", %{view: view} do
      log =
        capture_log([metadata: :all], fn ->
          VehicleView.apply_records(view, ["{not json", "{}"])
        end)

      assert log =~ "[warning]"
      assert log =~ "Vehicle view skipped invalid records"
      assert log =~ "invalid_count=2"
    end
  end

  describe "subscribe/1" do
    test "delivers one announcement when an agency's current fetch changes", %{view: view} do
      assert VehicleView.subscribe(%{view: view, pubsub: Gobusgo.PubSub}) == :ok

      :ok = VehicleView.apply_records(view, values(records(["1_a", "1_b"])))

      assert_received {:vehicle_view_switched, ^view}
      refute_received {:vehicle_view_switched, ^view}
    end

    test "delivers nothing while a fetch is held", %{view: view} do
      :ok = VehicleView.subscribe(%{view: view, pubsub: Gobusgo.PubSub})
      %{vehicles: vehicles} = records(["1_a", "1_b"])

      :ok = VehicleView.apply_records(view, Enum.map(vehicles, & &1.value))

      refute_received {:vehicle_view_switched, _view}
    end

    test "delivers nothing for the current fetch applied again", %{view: view} do
      :ok = VehicleView.apply_records(view, values(records(["1_a"])))
      :ok = VehicleView.subscribe(%{view: view, pubsub: Gobusgo.PubSub})

      :ok = VehicleView.apply_records(view, values(records(["1_a"])))

      refute_received {:vehicle_view_switched, _view}
    end
  end
end
