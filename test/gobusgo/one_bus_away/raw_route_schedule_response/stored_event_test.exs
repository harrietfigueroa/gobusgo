defmodule Gobusgo.OneBusAway.RawRouteScheduleResponse.StoredEventTest do
  # Verifies the schedule "response stored" record as a pure function of its
  # request: the expected event is written out by hand and compared with the
  # decoded record, and decode/1 is driven with records altered one rule at a
  # time.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.RawRoutePathResponse
  alias Gobusgo.OneBusAway.RawRouteScheduleResponse.StoredEvent

  @event_id "0199c4a2-7e1b-7a3f-9d20-0000000000ff"
  @request_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"
  @destination "raw/oba/schedule-for-route/dt=2026-11-06/route=19_41/service-date=2026-11-07/" <>
                 "20261106T231500Z_#{@request_id}_abababababab.json.gz"
  @data_sha256 String.duplicate("ab", 32)

  @response %{
    route_id: "19_41",
    service_date: ~D[2026-11-07],
    destination: @destination,
    fetched_at: ~U[2026-11-06 23:15:00Z],
    data_sha256: @data_sha256,
    request_id: @request_id
  }

  @request %{
    event_id: @event_id,
    source: "/gobusgo/test/oba/schedule-for-route",
    time: ~U[2026-11-06 23:15:01Z],
    response: @response
  }

  defp alter(value, path, change) do
    value |> JSON.decode!() |> update_in(path, change) |> Gobusgo.CanonicalJson.encode()
  end

  describe "record/1" do
    test "goes to the schedule event topic under the route's key" do
      assert Map.take(StoredEvent.record(@request), [:topic, :key]) == %{
               topic: "oba.schedules.response-stored",
               key: "oba/schedule-for-route/19_41"
             }
    end

    test "names the route and the service date in the event's data" do
      data = JSON.decode!(StoredEvent.record(@request).value)["data"]

      assert %{
               "dataset" => "oba/schedule-for-route",
               "routeId" => "19_41",
               "serviceDate" => "2026-11-07",
               "destination" => @destination
             } = data
    end

    test "raises for an empty route identifier" do
      assert_raise AssertionError, fn ->
        StoredEvent.record(put_in(@request, [:response, :route_id], ""))
      end
    end
  end

  describe "decode/1" do
    test "returns the event identifier, the route, the service date, and the stored response" do
      assert StoredEvent.decode(StoredEvent.record(@request).value) ==
               {:ok, Map.put(@response, :event_id, @event_id)}
    end

    for {name, change} <- [
          {"without a service date", {:delete, "serviceDate"}},
          {"with a service date that is not a date", {:put, "serviceDate", "2026-13-01"}},
          {"with an empty route", {:put, "routeId", ""}}
        ] do
      test "rejects an event #{name}" do
        value =
          alter(StoredEvent.record(@request).value, ["data"], fn data ->
            case unquote(Macro.escape(change)) do
              {:delete, key} -> Map.delete(data, key)
              {:put, key, value} -> Map.put(data, key, value)
            end
          end)

        assert StoredEvent.decode(value) == {:error, :schema_mismatch}
      end
    end

    test "rejects the event of another dataset" do
      route_path_response = Map.delete(@response, :service_date)

      other_event =
        RawRoutePathResponse.StoredEvent.record(%{@request | response: route_path_response})

      assert StoredEvent.decode(other_event.value) == {:error, :schema_mismatch}
    end
  end
end
