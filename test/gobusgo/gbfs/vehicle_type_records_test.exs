defmodule Gobusgo.Gbfs.VehicleTypeRecordsTest do
  # Verifies the published form of one fetch of a system's vehicle types at
  # one version as a pure function of the fetch: a record is built from
  # types written out here, decoded back, and decode/1 is driven with built
  # values altered one rule at a time.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.CloudEvent
  alias Gobusgo.Gbfs.VehicleTypeRecords

  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @fetched_at ~U[2026-11-08 19:08:00Z]

  defp fetch(overrides \\ %{}) do
    Map.merge(
      %{
        system_id: "lime_seattle",
        version: "3.0",
        request_id: @request_id,
        fetched_at: @fetched_at,
        vehicle_types: [
          %{
            id: "8",
            form_factor: "scooter_standing",
            propulsion_type: "electric",
            max_range_meters: 40_233
          },
          %{id: "4", form_factor: "bicycle", propulsion_type: "human", max_range_meters: nil}
        ]
      },
      overrides
    )
  end

  defp with_data(record, change) do
    {:ok, event} = CloudEvent.decode(record.value)
    CloudEvent.encode(%{event | data: change.(event.data)})
  end

  test "keys the record by system and version on the topic" do
    record = VehicleTypeRecords.build(fetch())

    assert %{topic: "gbfs.vehicle-types.state", key: "vehicle-types/lime_seattle/3.0"} = record
  end

  test "decodes what it builds, with the types by identifier" do
    record = VehicleTypeRecords.build(fetch())

    assert {:ok,
            %{
              id: "lime_seattle/3.0",
              system_id: "lime_seattle",
              version: "3.0",
              request_id: @request_id,
              fetched_at: @fetched_at,
              vehicle_types: %{
                "8" => %{
                  form_factor: "scooter_standing",
                  propulsion_type: "electric",
                  max_range_meters: 40_233
                },
                "4" => %{form_factor: "bicycle", propulsion_type: "human", max_range_meters: nil}
              }
            }} = VehicleTypeRecords.decode(record.value)
  end

  test "gives the view identifier of a system and a version" do
    assert VehicleTypeRecords.id(%{system_id: "lime_seattle", version: "2.2"}) ==
             "lime_seattle/2.2"
  end

  test "builds the same bytes from the same fetch" do
    assert VehicleTypeRecords.build(fetch()) == VehicleTypeRecords.build(fetch())
  end

  test "refuses a version that publishes no vehicle types" do
    assert_raise AssertionError, fn -> VehicleTypeRecords.build(fetch(%{version: "1.0"})) end
  end

  test "refuses a type identifier that repeats" do
    type = %{id: "8", form_factor: "other", propulsion_type: "human", max_range_meters: nil}

    assert_raise AssertionError, fn ->
      VehicleTypeRecords.build(fetch(%{vehicle_types: [type, type]}))
    end
  end

  test "passes over an event of another type" do
    event = %{
      id: "other",
      source: "/gobusgo/test",
      type: CloudEvent.type(%{name: "other.thing", version: 1}),
      time: @fetched_at,
      subject: "other",
      partition_key: "other",
      data: %{}
    }

    assert VehicleTypeRecords.decode(CloudEvent.encode(event)) == {:error, :unsupported_type}
  end

  test "reports a value that is not JSON" do
    assert VehicleTypeRecords.decode("not json") == {:error, :invalid_json}
  end

  defp change(:missing_version, data), do: Map.delete(data, "version")
  defp change(:version_without_types, data), do: Map.put(data, "version", "1.0")
  defp change(:invalid_request_id, data), do: Map.put(data, "requestId", "request")
  defp change(:invalid_fetch_time, data), do: Map.put(data, "fetchedAt", "yesterday")

  defp change(:type_without_form_factor, data) do
    Map.update!(data, "vehicleTypes", fn [type | rest] ->
      [Map.delete(type, "formFactor") | rest]
    end)
  end

  for {label, change} <- [
        {"a missing version", :missing_version},
        {"a version without types", :version_without_types},
        {"an invalid request identifier", :invalid_request_id},
        {"a fetch time that is no time", :invalid_fetch_time},
        {"a type without a form factor", :type_without_form_factor}
      ] do
    test "refuses #{label}" do
      record = VehicleTypeRecords.build(fetch())
      value = with_data(record, &change(unquote(change), &1))

      assert VehicleTypeRecords.decode(value) == {:error, :schema_mismatch}
    end
  end
end
