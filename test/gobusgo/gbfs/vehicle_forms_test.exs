defmodule Gobusgo.Gbfs.VehicleFormsTest do
  # Verifies lookup/2 as a pure function of the view's fetches: the fetches
  # are decoded from records built of Lime Seattle's recorded 2.2 and 3.0
  # `vehicle_types` files, and each case names the system, the version, and
  # the type identifier of one vehicle.
  use ExUnit.Case, async: true

  alias Gobusgo.Gbfs.Files
  alias Gobusgo.Gbfs.VehicleForms
  alias Gobusgo.Gbfs.VehicleTypeRecords

  @fixture_directory Path.expand("../../fixtures/gbfs", __DIR__)
  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @system_id "lime_seattle"

  defp fetch(version, fixture) do
    document =
      @fixture_directory |> Path.join(fixture <> ".json") |> File.read!() |> JSON.decode!()

    {:ok, %{vehicle_types: types}} = Files.vehicle_types(%{version: version, document: document})

    record =
      VehicleTypeRecords.build(%{
        system_id: @system_id,
        version: version,
        request_id: @request_id,
        fetched_at: ~U[2026-11-08 19:08:00Z],
        vehicle_types: types
      })

    {:ok, decoded} = VehicleTypeRecords.decode(record.value)
    decoded
  end

  defp fetches do
    [fetch("3.0", "lime_v3_vehicle_types"), fetch("2.2", "lime_v2_vehicle_types")]
  end

  defp lookup(version, vehicle_type_id, fetches \\ fetches()) do
    VehicleForms.lookup(fetches, %{
      system_id: @system_id,
      version: version,
      vehicle_type_id: vehicle_type_id
    })
  end

  for {version, type_id, form_factor, range} <- [
        {"3.0", "8", :standing_scooter, 40_233},
        {"2.2", "2", :standing_scooter, 40_233},
        {"3.0", "7", :seated_scooter, 24_140},
        {"3.0", "3", :e_bike, 85_000},
        {"2.2", "3", :e_bike, 85_000},
        {"3.0", "4", :bike, nil}
      ] do
    test "reads type #{type_id} of #{version} as #{form_factor}" do
      assert lookup(unquote(version), unquote(type_id)) == %{
               form_factor: unquote(form_factor),
               max_range_meters: unquote(range)
             }
    end
  end

  test "reads a type identifier in its own version alone" do
    assert lookup("2.2", "8") == %{form_factor: :other, max_range_meters: nil}
  end

  for {label, version, type_id} <- [
        {"a type the view does not hold", "3.0", "99"},
        {"a vehicle with no type", "3.0", nil},
        {"any vehicle of a 1.0 fetch", "1.0", "2"}
      ] do
    test "gives other for #{label}" do
      assert lookup(unquote(version), unquote(type_id)) ==
               %{form_factor: :other, max_range_meters: nil}
    end
  end

  test "gives other for a version the view holds no fetch of" do
    assert lookup("2.2", "2", [fetch("3.0", "lime_v3_vehicle_types")]) ==
             %{form_factor: :other, max_range_meters: nil}
  end

  test "gives other for a system the view holds no fetch of" do
    assert VehicleForms.lookup(fetches(), %{
             system_id: "another_system",
             version: "3.0",
             vehicle_type_id: "8"
           }) == %{form_factor: :other, max_range_meters: nil}
  end

  for {label, form_factor, propulsion_type} <- [
        {"a moped", "moped", "electric"},
        {"a car", "car", "combustion"},
        {"a bicycle with a combustion engine", "bicycle", "combustion"}
      ] do
    test "gives other for #{label}" do
      fetch = fetch("3.0", "lime_v3_vehicle_types")
      type = %{form_factor: unquote(form_factor), propulsion_type: unquote(propulsion_type)}
      fetch = put_in(fetch, [:vehicle_types, "50"], Map.put(type, :max_range_meters, 1_000))

      assert lookup("3.0", "50", [fetch]) == %{form_factor: :other, max_range_meters: 1_000}
    end
  end
end
