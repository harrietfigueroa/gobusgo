defmodule Gobusgo.OneBusAway.VehicleBatch.RecordsTest do
  # Verifies the published form of one agency's vehicle fetch as a pure
  # function of its input: expected keys and events are written out by hand
  # and compared with the decoded records, for a vehicle that supplies every
  # field and for one that supplies only its identifier.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.VehicleBatch.Records

  @request_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"
  @destination "raw/oba/vehicles-for-agency/agency=1/dt=2026-10-02/file.json"
  @data_sha256 String.duplicate("ab", 32)
  @topic "oba.vehicles-for-agency.state"
  @source "/gobusgo/processor/oba/vehicles-for-agency"
  @headers [{"content-type", "application/cloudevents+json"}]

  defp reported(id) do
    %{
      id: id,
      active_trip_id: "1_15436438",
      position: %{lat: 47.66, lon: -122.34},
      orientation: 202.5,
      last_known_location: %{lat: 47.65, lon: -122.33},
      last_known_orientation: 230.25,
      last_update_time_ms: 1_289_590_007_894,
      last_location_update_time_ms: 1_289_590_005_000,
      predicted: true
    }
  end

  defp bare(id) do
    %{
      id: id,
      active_trip_id: nil,
      position: nil,
      orientation: nil,
      last_known_location: nil,
      last_known_orientation: nil,
      last_update_time_ms: nil,
      last_location_update_time_ms: nil,
      predicted: nil
    }
  end

  defp fetch(vehicles) do
    %{
      agency_id: "1",
      destination: @destination,
      fetched_at: ~U[2026-10-02 03:15:00Z],
      data_sha256: @data_sha256,
      request_id: @request_id,
      vehicles: vehicles
    }
  end

  defp rewritten(record, change) do
    record.value |> JSON.decode!() |> change.() |> JSON.encode!()
  end

  describe "build/1 vehicle records" do
    test "holds one record per vehicle, in identifier order, keyed by agency and vehicle" do
      %{vehicles: records} = Records.build(fetch([bare("1_4207"), bare("1_1001")]))

      assert Enum.map(records, &Map.take(&1, [:topic, :key, :headers])) == [
               %{topic: @topic, key: "vehicle/1/1_1001", headers: @headers},
               %{topic: @topic, key: "vehicle/1/1_4207", headers: @headers}
             ]
    end

    test "carries every supplied field, the agency, and the fetch as a CloudEvent" do
      %{vehicles: [record]} = Records.build(fetch([reported("1_4207")]))

      assert JSON.decode!(record.value) == %{
               "specversion" => "1.0",
               "id" => "#{@request_id}/vehicle/1/1_4207",
               "source" => @source,
               "type" => "gobusgo.vehicle.processed.v1",
               "time" => "2026-10-02T03:15:00Z",
               "subject" => "1_4207",
               "datacontenttype" => "application/json",
               "partitionkey" => "vehicle/1/1_4207",
               "data" => %{
                 "vehicle" => %{
                   "id" => "1_4207",
                   "agencyId" => "1",
                   "activeTripId" => "1_15436438",
                   "position" => %{"lat" => 47.66, "lon" => -122.34},
                   "orientation" => 202.5,
                   "lastKnownLocation" => %{"lat" => 47.65, "lon" => -122.33},
                   "lastKnownOrientation" => 230.25,
                   "lastUpdateTimeMs" => 1_289_590_007_894,
                   "lastLocationUpdateTimeMs" => 1_289_590_005_000,
                   "predicted" => true
                 },
                 "fetchedAt" => "2026-10-02T03:15:00Z",
                 "requestId" => @request_id
               }
             }
    end

    test "carries a field the source did not supply as null" do
      %{vehicles: [record]} = Records.build(fetch([bare("1_4207")]))

      assert JSON.decode!(record.value)["data"]["vehicle"] == %{
               "id" => "1_4207",
               "agencyId" => "1",
               "activeTripId" => nil,
               "position" => nil,
               "orientation" => nil,
               "lastKnownLocation" => nil,
               "lastKnownOrientation" => nil,
               "lastUpdateTimeMs" => nil,
               "lastLocationUpdateTimeMs" => nil,
               "predicted" => nil
             }
    end

    test "keeps a zero location update time apart from one that was not supplied" do
      vehicle = %{bare("1_4207") | last_location_update_time_ms: 0}
      %{vehicles: [record]} = Records.build(fetch([vehicle]))

      assert JSON.decode!(record.value)["data"]["vehicle"]["lastLocationUpdateTimeMs"] === 0
    end

    test "is empty for a fetch without vehicles" do
      assert %{vehicles: []} = Records.build(fetch([]))
    end
  end

  describe "build/1 manifest record" do
    test "names the agency and every vehicle of the fetch, sorted, under the agency's key" do
      %{manifest: record} = Records.build(fetch([bare("1_4207"), bare("1_1001")]))

      assert Map.take(record, [:topic, :key, :headers]) ==
               %{topic: @topic, key: "manifest/1", headers: @headers}

      assert JSON.decode!(record.value) == %{
               "specversion" => "1.0",
               "id" => "#{@request_id}/manifest/1",
               "source" => @source,
               "type" => "gobusgo.vehicle.fetch.completed.v1",
               "time" => "2026-10-02T03:15:00Z",
               "subject" => @destination,
               "datacontenttype" => "application/json",
               "partitionkey" => "manifest/1",
               "data" => %{
                 "agencyId" => "1",
                 "vehicleIds" => ["1_1001", "1_4207"],
                 "dataSha256" => @data_sha256,
                 "destination" => @destination,
                 "fetchedAt" => "2026-10-02T03:15:00Z",
                 "requestId" => @request_id
               }
             }
    end
  end

  describe "build/1 determinism" do
    test "yields the same bytes whatever the order of the vehicles" do
      vehicles = [reported("1_4207"), bare("1_1001")]

      assert Records.build(fetch(vehicles)) == Records.build(fetch(Enum.reverse(vehicles)))
    end
  end

  describe "build/1 assertions" do
    test "raises for a request identifier that is not a UUID version 7" do
      assert_raise AssertionError, ~r/request identifier/, fn ->
        Records.build(%{fetch([]) | request_id: "request"})
      end
    end

    test "raises for an empty agency identifier" do
      assert_raise AssertionError, ~r/agency identifier/, fn ->
        Records.build(%{fetch([]) | agency_id: ""})
      end
    end

    test "raises for a vehicle listed twice" do
      assert_raise AssertionError, ~r/unique/, fn ->
        Records.build(fetch([bare("1_4207"), bare("1_4207")]))
      end
    end
  end

  describe "decode/1" do
    test "returns the vehicle, its agency, and its fetch for a vehicle record" do
      %{vehicles: [record]} = Records.build(fetch([reported("1_4207")]))

      assert Records.decode(record.value) ==
               {:ok,
                {:vehicle,
                 %{
                   request_id: @request_id,
                   fetched_at: ~U[2026-10-02 03:15:00Z],
                   agency_id: "1",
                   vehicle: %{
                     "id" => "1_4207",
                     "agencyId" => "1",
                     "activeTripId" => "1_15436438",
                     "position" => %{"lat" => 47.66, "lon" => -122.34},
                     "orientation" => 202.5,
                     "lastKnownLocation" => %{"lat" => 47.65, "lon" => -122.33},
                     "lastKnownOrientation" => 230.25,
                     "lastUpdateTimeMs" => 1_289_590_007_894,
                     "lastLocationUpdateTimeMs" => 1_289_590_005_000,
                     "predicted" => true
                   }
                 }}}
    end

    test "returns null for every field a vehicle record did not supply" do
      %{vehicles: [record]} = Records.build(fetch([bare("1_4207")]))

      assert {:ok, {:vehicle, %{vehicle: vehicle}}} = Records.decode(record.value)
      assert vehicle["position"] == nil
      assert vehicle["lastKnownLocation"] == nil
      assert vehicle["lastLocationUpdateTimeMs"] == nil
      assert vehicle["predicted"] == nil
    end

    test "returns the membership and the provenance of a manifest record" do
      %{manifest: record} = Records.build(fetch([bare("1_4207"), bare("1_1001")]))

      assert Records.decode(record.value) ==
               {:ok,
                {:manifest,
                 %{
                   request_id: @request_id,
                   fetched_at: ~U[2026-10-02 03:15:00Z],
                   agency_id: "1",
                   vehicle_ids: ["1_1001", "1_4207"],
                   data_sha256: @data_sha256,
                   destination: @destination
                 }}}
    end

    test "drops vehicle and position fields it does not know" do
      %{vehicles: [record]} = Records.build(fetch([reported("1_4207")]))

      value =
        rewritten(record, fn event ->
          event
          |> put_in(["data", "vehicle", "occupancyStatus"], "FULL")
          |> put_in(["data", "vehicle", "position", "altitude"], 12.5)
        end)

      assert {:ok, {:vehicle, %{vehicle: vehicle}}} = Records.decode(value)
      refute is_map_key(vehicle, "occupancyStatus")
      assert vehicle["position"] == %{"lat" => 47.66, "lon" => -122.34}
    end

    test "returns invalid_json for a value that is not JSON" do
      assert Records.decode("{not json") == {:error, :invalid_json}
    end

    test "returns unsupported_type for an event of another type" do
      %{manifest: record} = Records.build(fetch([]))
      value = rewritten(record, &Map.put(&1, "type", "gobusgo.vehicle.fetch.completed.v2"))

      assert Records.decode(value) == {:error, :unsupported_type}
    end

    for {description, change} <- [
          {"a value that is not a CloudEvent", quote(do: &Map.delete(&1, "specversion"))},
          {"a vehicle without its position key",
           quote(do: &(pop_in(&1, ["data", "vehicle", "position"]) |> elem(1)))},
          {"a vehicle with an empty identifier",
           quote(do: &put_in(&1, ["data", "vehicle", "id"], ""))},
          {"a vehicle with an empty agency identifier",
           quote(do: &put_in(&1, ["data", "vehicle", "agencyId"], ""))},
          {"a position without a longitude",
           quote(do: &put_in(&1, ["data", "vehicle", "position"], %{"lat" => 47.5}))},
          {"a latitude that is not a number",
           quote(do: &put_in(&1, ["data", "vehicle", "position", "lat"], "north"))},
          {"a location update time that is not an integer",
           quote(do: &put_in(&1, ["data", "vehicle", "lastLocationUpdateTimeMs"], 1.5))},
          {"a negative location update time",
           quote(do: &put_in(&1, ["data", "vehicle", "lastLocationUpdateTimeMs"], -1))},
          {"a negative update time",
           quote(do: &put_in(&1, ["data", "vehicle", "lastUpdateTimeMs"], -1))},
          {"a predicted flag that is not a boolean",
           quote(do: &put_in(&1, ["data", "vehicle", "predicted"], "yes"))},
          {"a fetch time that is not a time",
           quote(do: &put_in(&1, ["data", "fetchedAt"], "yesterday"))},
          {"a request identifier that is not a UUID version 7",
           quote(do: &put_in(&1, ["data", "requestId"], "request"))}
        ] do
      test "returns schema_mismatch for #{description}" do
        %{vehicles: [record]} = Records.build(fetch([reported("1_4207")]))

        assert Records.decode(rewritten(record, unquote(change))) == {:error, :schema_mismatch}
      end
    end

    for {description, change} <- [
          {"vehicle identifiers that are not strings",
           quote(do: &put_in(&1, ["data", "vehicleIds"], [1]))},
          {"an empty agency identifier", quote(do: &put_in(&1, ["data", "agencyId"], ""))}
        ] do
      test "returns schema_mismatch for a manifest with #{description}" do
        %{manifest: record} = Records.build(fetch([bare("1_4207")]))

        assert Records.decode(rewritten(record, unquote(change))) == {:error, :schema_mismatch}
      end
    end
  end
end
