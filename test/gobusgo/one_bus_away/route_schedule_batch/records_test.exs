defmodule Gobusgo.OneBusAway.RouteScheduleBatch.RecordsTest do
  # Verifies the published form of a route schedule as a pure function of the
  # stored response: the stored response is built from the live fixture with
  # RawRouteScheduleResponse.build/1 and parsed back as the processor does,
  # and decode/1 is driven with the record build/1 produces, then altered one
  # rule at a time.
  use ExUnit.Case, async: true

  alias Gobusgo.CloudEvent
  alias Gobusgo.OneBusAway.CompactSchedule
  alias Gobusgo.OneBusAway.RawRouteScheduleResponse
  alias Gobusgo.OneBusAway.RouteScheduleBatch.Records
  alias Gobusgo.OneBusAway.RouteSchedules

  @fixture_path Path.expand("../../../fixtures/one_bus_away/schedule_for_route.json", __DIR__)
  @request_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"
  @fetched_at ~U[2026-11-06 23:15:00Z]

  defp parsed do
    envelope = @fixture_path |> File.read!() |> JSON.decode!()
    {:ok, schedule} = RouteSchedules.parse(envelope["data"], "19_41")

    stored =
      RawRouteScheduleResponse.build(%{
        request_id: @request_id,
        response: %{
          route_id: "19_41",
          service_date: ~D[2026-11-07],
          schedule: schedule,
          envelope: envelope,
          fetched_at: @fetched_at,
          host: "oba.example.test",
          http_status: 200,
          method: "GET"
        }
      })

    {:ok, parsed} = RawRouteScheduleResponse.parse(stored)
    parsed
  end

  defp alter_data(value, key, new) do
    event = JSON.decode!(value)
    Gobusgo.CanonicalJson.encode(put_in(event, ["data", key], new))
  end

  describe "build/1" do
    test "goes to the schedule state topic under the route and the service date" do
      assert %{topic: "oba.schedules.state", key: "schedule-for-route/19_41/2026-11-07"} =
               Records.build(parsed())
    end

    test "yields the same bytes for a repeated build" do
      assert Records.build(parsed()) == Records.build(parsed())
    end

    test "holds the route's stops once and each trip's stops as indexes" do
      %{value: value} = Records.build(parsed())
      {:ok, %{data: data}} = CloudEvent.decode(value)
      [first_trip | _trips] = data["trips"]
      [first_stop_time | _stop_times] = hd(parsed().schedule.trips).stop_times

      assert Enum.at(data["stopIds"], hd(first_trip["stopIndexes"])) == first_stop_time.stop_id
    end
  end

  describe "decode/1" do
    test "returns the fetch with its schedule packed" do
      %{value: value} = Records.build(parsed())

      assert {:ok,
              %{
                id: "19_41",
                service_date: ~D[2026-11-07],
                request_id: @request_id,
                fetched_at: @fetched_at,
                schedule: %{route_id: "19_41", stop_time_count: 64}
              }} = Records.decode(value)
    end

    test "gives back the stop times the stored response holds" do
      %{value: value} = Records.build(parsed())
      {:ok, %{schedule: compact}} = Records.decode(value)

      assert Enum.map(compact.trips, &CompactSchedule.stop_times(compact, &1)) ==
               Enum.map(parsed().schedule.trips, & &1.stop_times)
    end

    test "returns unsupported type for an event of another type" do
      value =
        CloudEvent.record("oba.schedules.state", %{
          id: "other",
          source: "/other",
          type: CloudEvent.type(%{name: "other.thing", version: 1}),
          time: @fetched_at,
          subject: "19_41",
          partition_key: "other",
          data: %{}
        }).value

      assert Records.decode(value) == {:error, :unsupported_type}
    end

    for {name, key, new} <- [
          {"a service date that is not a date", "serviceDate", "tomorrow"},
          {"an empty route identifier", "routeId", ""},
          {"a request identifier that is not a UUID version 7", "requestId", "request"},
          {"trips that are not a list", "trips", "none"}
        ] do
      test "returns a schema mismatch for #{name}" do
        %{value: value} = Records.build(parsed())

        assert Records.decode(alter_data(value, unquote(key), unquote(new))) ==
                 {:error, :schema_mismatch}
      end
    end

    test "returns a schema mismatch for a trip that names a stop the route does not have" do
      %{value: value} = Records.build(parsed())

      assert Records.decode(alter_data(value, "stopIds", [])) == {:error, :schema_mismatch}
    end
  end
end
