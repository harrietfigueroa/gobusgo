defmodule Gobusgo.OneBusAway.RawArrivalResponse.StoredEventTest do
  # Verifies the arrivals "response stored" record as a pure function of its
  # request: the expected event is written out by hand and compared with the
  # decoded record, and decode/1 is driven with records altered one rule at a
  # time.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.OneBusAway.RawArrivalResponse.StoredEvent

  @event_id "0199c4a2-7e1b-7a3f-9d20-0000000000ff"
  @request_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"
  @destination "raw/oba/arrivals-and-departures-for-stop/dt=2026-10-02/stop=95_7/" <>
                 "20261002T031500Z_#{@request_id}_abababababab.json.gz"
  @data_sha256 String.duplicate("ab", 32)

  @response %{
    stop_id: "95_7",
    destination: @destination,
    fetched_at: ~U[2026-10-02 03:15:00Z],
    data_sha256: @data_sha256,
    request_id: @request_id
  }

  @request %{
    event_id: @event_id,
    source: "/gobusgo/test/oba/arrivals-and-departures-for-stop",
    time: ~U[2026-10-02 03:15:01Z],
    response: @response
  }

  defp alter(value, path, change) do
    value |> JSON.decode!() |> update_in(path, change) |> Gobusgo.CanonicalJson.encode()
  end

  describe "record/1" do
    test "goes to the arrivals event topic under the stop's key" do
      assert Map.take(StoredEvent.record(@request), [:topic, :key, :headers]) == %{
               topic: "oba.arrivals.response-stored",
               key: "oba/arrivals-and-departures-for-stop/95_7",
               headers: [{"content-type", "application/cloudevents+json"}]
             }
    end

    test "refers to the stored response and its stop as a CloudEvent" do
      assert JSON.decode!(StoredEvent.record(@request).value) == %{
               "specversion" => "1.0",
               "id" => @event_id,
               "source" => "/gobusgo/test/oba/arrivals-and-departures-for-stop",
               "type" => "gobusgo.response.stored.v1",
               "time" => "2026-10-02T03:15:01Z",
               "subject" => @destination,
               "datacontenttype" => "application/json",
               "partitionkey" => "oba/arrivals-and-departures-for-stop/95_7",
               "data" => %{
                 "stopId" => "95_7",
                 "dataset" => "oba/arrivals-and-departures-for-stop",
                 "destination" => @destination,
                 "fetchedAt" => "2026-10-02T03:15:00Z",
                 "dataSha256" => @data_sha256,
                 "requestId" => @request_id
               }
             }
    end

    test "raises for an empty stop identifier" do
      assert_raise AssertionError, fn ->
        StoredEvent.record(put_in(@request, [:response, :stop_id], ""))
      end
    end
  end

  describe "decode/1" do
    test "returns the event identifier, the stop, and the stored response" do
      assert StoredEvent.decode(StoredEvent.record(@request).value) ==
               {:ok, Map.put(@response, :event_id, @event_id)}
    end

    test "rejects an event without a stop" do
      value =
        alter(StoredEvent.record(@request).value, ["data"], &Map.delete(&1, "stopId"))

      assert StoredEvent.decode(value) == {:error, :schema_mismatch}
    end

    test "rejects an event with an empty stop" do
      value = alter(StoredEvent.record(@request).value, ["data", "stopId"], fn _id -> "" end)

      assert StoredEvent.decode(value) == {:error, :schema_mismatch}
    end

    test "rejects the event of another dataset" do
      other_event =
        RawAgencyResponse.StoredEvent.record(%{@request | response: @response})

      assert StoredEvent.decode(other_event.value) == {:error, :schema_mismatch}
    end

    test "rejects a value that is not JSON" do
      assert StoredEvent.decode("{") == {:error, :invalid_json}
    end
  end
end
