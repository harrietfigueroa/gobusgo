defmodule Gobusgo.Gbfs.FilesTest do
  # Verifies the parsers as pure functions of a decoded document: the recorded
  # Lime Seattle files of each version give the records they hold, and a
  # recorded file with one field broken gives the cause that names it.
  use ExUnit.Case, async: true

  alias Gobusgo.Gbfs.Files

  @fixture_directory Path.expand("../../fixtures/gbfs", __DIR__)

  defp fixture(name) do
    @fixture_directory |> Path.join(name <> ".json") |> File.read!() |> JSON.decode!()
  end

  defp first_vehicle_put(document, key, value) do
    data_key =
      Map.fetch!(%{"1.0" => "bikes", "2.2" => "bikes", "3.0" => "vehicles"}, document["version"])

    update_in(document, ["data", data_key], fn [first | rest] ->
      [Map.put(first, key, value) | rest]
    end)
  end

  defp first_vehicle_delete(document, key) do
    data_key =
      Map.fetch!(%{"1.0" => "bikes", "2.2" => "bikes", "3.0" => "vehicles"}, document["version"])

    update_in(document, ["data", data_key], fn [first | rest] ->
      [Map.delete(first, key) | rest]
    end)
  end

  describe "discovery/3" do
    for {version, fixture, url} <- [
          {"1.0", "lime_v1_gbfs",
           "https://data.lime.bike/api/partners/v1/gbfs/seattle/free_bike_status"},
          {"2.2", "lime_v2_gbfs",
           "https://data.lime.bike/api/partners/v2/gbfs/seattle/free_bike_status"},
          {"3.0", "lime_v3_gbfs",
           "https://data.lime.bike/api/partners/v3/gbfs/seattle/vehicle_status.json"}
        ] do
      test "names the vehicle file's address for GBFS #{version}" do
        assert {:ok, %{feeds: feeds}} =
                 Files.discovery(%{
                   version: unquote(version),
                   document: fixture(unquote(fixture)),
                   language: "en"
                 })

        assert Map.fetch!(feeds, Files.vehicle_status_name(unquote(version))) == unquote(url)
      end
    end

    test "returns the discovery file's last_updated and ttl" do
      assert {:ok, %{last_updated: last_updated, ttl: 0}} =
               Files.discovery(%{
                 version: "2.2",
                 document: fixture("lime_v2_gbfs"),
                 language: "en"
               })

      assert last_updated == ~U[2026-11-08 19:07:18Z]
    end

    test "returns a schema mismatch at the language a 2.2 file does not publish" do
      assert Files.discovery(%{version: "2.2", document: fixture("lime_v2_gbfs"), language: "fr"}) ==
               {:error, {:schema_mismatch, %{path: ["data", "fr"], expected: :required}}}
    end

    test "reads a 3.0 file whatever the language, since its feeds are not split by language" do
      assert {:ok, %{feeds: feeds}} =
               Files.discovery(%{
                 version: "3.0",
                 document: fixture("lime_v3_gbfs"),
                 language: "fr"
               })

      assert Map.has_key?(feeds, "vehicle_status")
    end
  end

  describe "vehicle_status/2" do
    test "parses a 3.0 vehicle_status file" do
      assert {:ok,
              %{last_updated: ~U[2026-11-08 19:07:58Z], ttl: 60, vehicles: [vehicle, _second]}} =
               Files.vehicle_status(%{
                 version: "3.0",
                 document: fixture("lime_v3_vehicle_status")
               })

      assert vehicle == %{
               id: "c7629d49-7090-48ed-b32d-525ac3435490",
               position: %{lat: 47.639769, lon: -122.403769},
               vehicle_type_id: "8",
               current_range_meters: 34247,
               is_disabled: false,
               is_reserved: false,
               last_reported: ~U[2026-11-08 19:07:55Z]
             }
    end

    test "parses a 2.2 free_bike_status file" do
      assert {:ok,
              %{last_updated: ~U[2026-11-08 19:07:26Z], ttl: 60, vehicles: [vehicle, _second]}} =
               Files.vehicle_status(%{
                 version: "2.2",
                 document: fixture("lime_v2_free_bike_status")
               })

      assert vehicle == %{
               id: "c7629d49-7090-48ed-b32d-525ac3435490",
               position: %{lat: 47.639769, lon: -122.403769},
               vehicle_type_id: "2",
               current_range_meters: 34247,
               is_disabled: false,
               is_reserved: false,
               last_reported: ~U[2026-11-08 19:06:31Z]
             }
    end

    test "parses a 1.0 free_bike_status file, whose flags are 1 and 0" do
      assert {:ok, %{ttl: 0, vehicles: [vehicle, _second]}} =
               Files.vehicle_status(%{
                 version: "1.0",
                 document: fixture("lime_v1_free_bike_status")
               })

      assert vehicle == %{
               id: "668fb735-4b14-4bdc-87e8-cdc09cd7a1dd",
               position: %{lat: 47.6398, lon: -122.4038},
               vehicle_type_id: nil,
               current_range_meters: nil,
               is_disabled: false,
               is_reserved: false,
               last_reported: nil
             }
    end

    test "reads a 1.0 flag of 1 as true" do
      document = fixture("lime_v1_free_bike_status") |> first_vehicle_put("is_reserved", 1)

      assert {:ok, %{vehicles: [%{is_reserved: true} | _rest]}} =
               Files.vehicle_status(%{version: "1.0", document: document})
    end

    test "returns no position for a vehicle that names neither coordinate" do
      document =
        fixture("lime_v3_vehicle_status")
        |> first_vehicle_delete("lat")
        |> first_vehicle_delete("lon")

      assert {:ok, %{vehicles: [%{position: nil} | _rest]}} =
               Files.vehicle_status(%{version: "3.0", document: document})
    end

    test "returns an empty list for a feed with no vehicles" do
      document = put_in(fixture("lime_v3_vehicle_status"), ["data", "vehicles"], [])

      assert {:ok, %{vehicles: []}} = Files.vehicle_status(%{version: "3.0", document: document})
    end

    for {name, version, fixture, arrange, cause} <- [
          {"a 3.0 flag that is not a boolean", "3.0", "lime_v3_vehicle_status",
           quote(do: &first_vehicle_put(&1, "is_disabled", "no")),
           {:schema_mismatch, %{path: ["data", "vehicles", 0, "is_disabled"], expected: :boolean}}},
          {"a 2.2 file with a 3.0 timestamp", "2.2", "lime_v2_free_bike_status",
           quote(do: &Map.put(&1, "last_updated", "2026-11-08T19:07:58Z")),
           {:schema_mismatch, %{path: ["last_updated"], expected: :integer}}},
          {"a 3.0 timestamp that is not RFC 3339", "3.0", "lime_v3_vehicle_status",
           quote(do: &first_vehicle_put(&1, "last_reported", "yesterday")),
           {:invalid_timestamp, ["data", "vehicles", 0, "last_reported"]}},
          {"a latitude past the pole", "3.0", "lime_v3_vehicle_status",
           quote(do: &first_vehicle_put(&1, "lat", 91.0)),
           {:out_of_range, ["data", "vehicles", 0, "lat"]}},
          {"a longitude without a latitude", "3.0", "lime_v3_vehicle_status",
           quote(do: &first_vehicle_delete(&1, "lat")),
           {:schema_mismatch, %{path: ["data", "vehicles", 0, "lat"], expected: :required}}},
          {"a negative range", "2.2", "lime_v2_free_bike_status",
           quote(do: &first_vehicle_put(&1, "current_range_meters", -1)),
           {:out_of_range, ["data", "bikes", 0, "current_range_meters"]}},
          {"a 1.0 flag of 2", "1.0", "lime_v1_free_bike_status",
           quote(do: &first_vehicle_put(&1, "is_disabled", 2)),
           {:out_of_range, ["data", "bikes", 0, "is_disabled"]}},
          {"a negative ttl", "3.0", "lime_v3_vehicle_status", quote(do: &Map.put(&1, "ttl", -60)),
           {:out_of_range, ["ttl"]}},
          {"a 2.2 file without its version", "2.2", "lime_v2_free_bike_status",
           quote(do: &Map.delete(&1, "version")),
           {:schema_mismatch, %{path: ["version"], expected: :required}}}
        ] do
      test "returns the cause for #{name}" do
        document = unquote(arrange).(fixture(unquote(fixture)))

        assert Files.vehicle_status(%{version: unquote(version), document: document}) ==
                 {:error, unquote(Macro.escape(cause))}
      end
    end
  end

  describe "vehicle_types/2" do
    for {version, fixture, count, first} <- [
          {"2.2", "lime_v2_vehicle_types", 4,
           %{
             id: "1",
             form_factor: "scooter",
             propulsion_type: "electric",
             max_range_meters: 24140
           }},
          {"3.0", "lime_v3_vehicle_types", 7,
           %{
             id: "3",
             form_factor: "bicycle",
             propulsion_type: "electric_assist",
             max_range_meters: 85000
           }}
        ] do
      test "parses a #{version} vehicle_types file" do
        assert {:ok, %{ttl: 86_400, vehicle_types: [first | _rest] = vehicle_types}} =
                 Files.vehicle_types(%{
                   version: unquote(version),
                   document: fixture(unquote(fixture))
                 })

        assert length(vehicle_types) == unquote(count)
        assert first == unquote(Macro.escape(first))
      end
    end

    test "returns no maximum range for a human-powered type" do
      assert {:ok, %{vehicle_types: vehicle_types}} =
               Files.vehicle_types(%{version: "2.2", document: fixture("lime_v2_vehicle_types")})

      assert %{id: "4", propulsion_type: "human", max_range_meters: nil} =
               List.last(vehicle_types)
    end

    test "returns a schema mismatch for a type without a form factor" do
      document =
        update_in(fixture("lime_v3_vehicle_types"), ["data", "vehicle_types"], fn [first | rest] ->
          [Map.delete(first, "form_factor") | rest]
        end)

      assert Files.vehicle_types(%{version: "3.0", document: document}) ==
               {:error,
                {:schema_mismatch,
                 %{path: ["data", "vehicle_types", 0, "form_factor"], expected: :required}}}
    end
  end
end
