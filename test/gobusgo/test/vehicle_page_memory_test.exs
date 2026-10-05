defmodule Gobusgo.Test.VehiclePageMemoryTest do
  # Fills the application's vehicle view with the synthetic fetches the
  # helper builds and reads the view back, and measures this test's own
  # process. Each test restarts that view, which is global state, hence the
  # non-async case.
  use ExUnit.Case, async: false

  alias Gobusgo.OneBusAway.VehicleView
  alias Gobusgo.Publisher
  alias Gobusgo.Test.VehiclePageMemory

  @moduletag capture_log: true

  setup do
    restart_view()
    on_exit(&restart_view/0)
  end

  defp restart_view do
    :ok = Supervisor.terminate_child(Gobusgo.Supervisor, VehicleView)
    {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, VehicleView)
  end

  defp apply_fetch(fetch), do: VehiclePageMemory.apply_fetch(VehicleView, fetch)

  describe "fetch_profile/0" do
    test "names each agency once" do
      agency_ids = Enum.map(VehiclePageMemory.fetch_profile(), & &1.agency_id)

      assert agency_ids == Enum.uniq(agency_ids)
    end
  end

  describe "apply_fetch/2" do
    test "gives the agency a current fetch with the vehicle count asked for" do
      :ok = apply_fetch(%{agency_id: "40", vehicle_count: 3, sequence: 0})

      assert [%{agency_id: "40", vehicle_ids: [_first, _second, _third]}] =
               VehicleView.current(VehicleView)
    end

    test "completes a fetch of more vehicles than one call of the view takes" do
      vehicle_count = Publisher.record_count_max() + 1

      :ok = apply_fetch(%{agency_id: "1", vehicle_count: vehicle_count, sequence: 0})

      assert [%{vehicle_ids: vehicle_ids}] = VehicleView.current(VehicleView)
      assert length(vehicle_ids) == vehicle_count
    end

    test "completes a fetch of no vehicles" do
      :ok = apply_fetch(%{agency_id: "19", vehicle_count: 0, sequence: 0})

      assert [%{agency_id: "19", vehicle_ids: []}] = VehicleView.current(VehicleView)
    end

    test "replaces the agency's fetch with the one of a later sequence" do
      :ok = apply_fetch(%{agency_id: "40", vehicle_count: 2, sequence: 0})
      [%{request_id: first_request_id}] = VehicleView.current(VehicleView)

      :ok = apply_fetch(%{agency_id: "40", vehicle_count: 2, sequence: 1})

      assert [%{request_id: request_id}] = VehicleView.current(VehicleView)
      assert request_id != first_request_id
    end

    test "moves a vehicle between two sequences" do
      :ok = apply_fetch(%{agency_id: "40", vehicle_count: 1, sequence: 0})
      [%{vehicle_ids: [id], vehicles: first_vehicles}] = VehicleView.current(VehicleView)

      :ok = apply_fetch(%{agency_id: "40", vehicle_count: 1, sequence: 1})

      [%{vehicles: vehicles}] = VehicleView.current(VehicleView)
      assert vehicles[id]["position"] != first_vehicles[id]["position"]
    end

    test "leaves the fetch of another agency as it is" do
      :ok = apply_fetch(%{agency_id: "1", vehicle_count: 1, sequence: 0})
      :ok = apply_fetch(%{agency_id: "40", vehicle_count: 2, sequence: 1})

      assert [%{agency_id: "1", vehicle_ids: [_only]}, %{agency_id: "40"}] =
               VehicleView.current(VehicleView)
    end
  end

  describe "process_memory/1" do
    test "counts the bytes of a binary the process refers to" do
      size = 1_000_000
      binary = :binary.copy(<<0>>, size)

      assert %{binary_bytes: binary_bytes} = VehiclePageMemory.process_memory(self())
      assert binary_bytes >= byte_size(binary)
    end

    test "reports a heap no larger than the process's memory" do
      assert %{memory_bytes: memory_bytes, heap_bytes: heap_bytes} =
               VehiclePageMemory.process_memory(self())

      assert heap_bytes > 0
      assert heap_bytes <= memory_bytes
    end
  end

  describe "table_memory_bytes/1" do
    test "grows when the view takes a fetch" do
      empty_bytes = VehiclePageMemory.table_memory_bytes(VehicleView)

      :ok = apply_fetch(%{agency_id: "40", vehicle_count: 50, sequence: 0})

      assert VehiclePageMemory.table_memory_bytes(VehicleView) > empty_bytes
    end
  end

  describe "identifier_retention/1" do
    test "counts the bytes of every current vehicle identifier" do
      :ok = apply_fetch(%{agency_id: "40", vehicle_count: 2, sequence: 0})
      [%{vehicle_ids: vehicle_ids}] = VehicleView.current(VehicleView)

      assert %{identifier_bytes: identifier_bytes} =
               VehiclePageMemory.identifier_retention(VehicleView)

      assert identifier_bytes == vehicle_ids |> Enum.map(&byte_size/1) |> Enum.sum()
    end

    test "counts at least those bytes as kept alive" do
      :ok = apply_fetch(%{agency_id: "40", vehicle_count: 2, sequence: 0})

      assert %{identifier_bytes: identifier_bytes, referenced_bytes: referenced_bytes} =
               VehiclePageMemory.identifier_retention(VehicleView)

      assert referenced_bytes >= identifier_bytes
    end
  end
end
