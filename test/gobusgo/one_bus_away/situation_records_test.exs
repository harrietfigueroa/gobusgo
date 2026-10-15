defmodule Gobusgo.OneBusAway.SituationRecordsTest do
  # Builds the situations record of each source from the live fixture's
  # situations, reads it back through the source's own decode/1, and alters
  # one rule at a time to check that the record is refused, and that a
  # source's decode/1 passes over the other source's record as the fetch
  # view requires.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.ArrivalBatch
  alias Gobusgo.OneBusAway.Situations
  alias Gobusgo.OneBusAway.VehicleBatch

  @fixture_path Path.expand("../../fixtures/one_bus_away/situations.json", __DIR__)
  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @fetched_at ~U[2026-10-15 16:10:00Z]

  defp situations do
    %{situations: situations} =
      @fixture_path |> File.read!() |> JSON.decode!() |> Situations.parse()

    situations
  end

  defp fetch(overrides) do
    Map.merge(
      %{
        request_id: @request_id,
        fetched_at: @fetched_at,
        data_sha256: String.duplicate("a", 64),
        destination: "raw/oba/example/dt=2026-10-15/x.json.gz",
        situations: situations()
      },
      overrides
    )
  end

  defp vehicle_record(overrides \\ %{}) do
    VehicleBatch.SituationRecords.build(Map.merge(fetch(%{agency_id: "40"}), overrides))
  end

  defp arrival_record(overrides \\ %{}) do
    ArrivalBatch.SituationRecords.build(Map.merge(fetch(%{stop_id: "1_67655"}), overrides))
  end

  describe "build/1" do
    test "names the agency of a vehicle fetch in the key, the id, and the type" do
      record = vehicle_record()
      event = JSON.decode!(record.value)

      assert record.topic == "oba.situations.state"
      assert record.key == "vehicles/40"
      assert event["id"] == @request_id <> "/situations/vehicles/40"
      assert event["type"] == "gobusgo.agency.situations.processed.v1"
      assert event["source"] == "/gobusgo/processor/oba/vehicles-for-agency"
      assert event["data"]["agencyId"] == "40"
    end

    test "names the stop of an arrivals fetch in the key, the id, and the type" do
      record = arrival_record()
      event = JSON.decode!(record.value)

      assert record.key == "arrivals/1_67655"
      assert event["id"] == @request_id <> "/situations/arrivals/1_67655"
      assert event["type"] == "gobusgo.stop.situations.processed.v1"
      assert event["source"] == "/gobusgo/processor/oba/arrivals-and-departures-for-stop"
      assert event["data"]["stopId"] == "1_67655"
    end

    test "yields the same bytes for the same fetch" do
      assert vehicle_record() == vehicle_record()
    end

    for {name, overrides} <- [
          {"an empty agency", %{agency_id: ""}},
          {"a request identifier that is no UUID version 7", %{request_id: "request"}}
        ] do
      test "raises for #{name}" do
        assert_raise AssertionError, fn -> vehicle_record(unquote(Macro.escape(overrides))) end
      end
    end

    test "raises for a situation identifier that repeats" do
      [first | _rest] = situations()

      assert_raise AssertionError, fn -> vehicle_record(%{situations: [first, first]}) end
    end
  end

  describe "decode/1" do
    test "reads back the fetch a vehicle record holds" do
      assert VehicleBatch.SituationRecords.decode(vehicle_record().value) ==
               {:ok,
                %{
                  id: "40",
                  request_id: @request_id,
                  fetched_at: @fetched_at,
                  data_sha256: String.duplicate("a", 64),
                  destination: "raw/oba/example/dt=2026-10-15/x.json.gz",
                  situations: situations()
                }}
    end

    test "reads back the fetch an arrivals record holds" do
      assert {:ok, %{id: "1_67655", situations: decoded}} =
               ArrivalBatch.SituationRecords.decode(arrival_record().value)

      assert decoded == situations()
    end

    test "passes over the other source's record" do
      assert VehicleBatch.SituationRecords.decode(arrival_record().value) ==
               {:error, :unsupported_type}

      assert ArrivalBatch.SituationRecords.decode(vehicle_record().value) ==
               {:error, :unsupported_type}
    end

    test "refuses a value that is not JSON" do
      assert VehicleBatch.SituationRecords.decode("{") == {:error, :invalid_json}
    end

    for {name, path, value} <- [
          {"an empty agency", ["data", "agencyId"], ""},
          {"a request identifier that is no UUID version 7", ["data", "requestId"], "request"},
          {"a fetch time that is no time", ["data", "fetchedAt"], "soon"}
        ] do
      test "refuses a record with #{name}" do
        value =
          vehicle_record().value
          |> JSON.decode!()
          |> put_in(unquote(path), unquote(value))
          |> JSON.encode!()

        assert VehicleBatch.SituationRecords.decode(value) == {:error, :schema_mismatch}
      end
    end

    test "refuses a record whose situation identifiers repeat" do
      event = JSON.decode!(vehicle_record().value)
      [first | _rest] = event["data"]["situations"]
      value = event |> put_in(["data", "situations"], [first, first]) |> JSON.encode!()

      assert VehicleBatch.SituationRecords.decode(value) == {:error, :schema_mismatch}
    end

    test "refuses a record with a situation that has no summary" do
      event = JSON.decode!(vehicle_record().value)
      [first | rest] = event["data"]["situations"]
      altered = [Map.put(first, "summary", nil) | rest]
      value = event |> put_in(["data", "situations"], altered) |> JSON.encode!()

      assert VehicleBatch.SituationRecords.decode(value) == {:error, :schema_mismatch}
    end
  end
end
