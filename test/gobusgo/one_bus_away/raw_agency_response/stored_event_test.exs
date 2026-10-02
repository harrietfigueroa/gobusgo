defmodule Gobusgo.OneBusAway.RawAgencyResponse.StoredEventTest do
  # Verifies the "response stored" record as a pure function of its request:
  # the expected event is written out by hand and compared with the decoded
  # record.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.RawAgencyResponse.StoredEvent

  @event_id "0199c4a2-7e1b-7a3f-9d20-0000000000ff"
  @request_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"
  @destination "raw/oba/agencies-with-coverage/dt=2026-10-02/" <>
                 "20261002T031500Z_#{@request_id}_abababababab.json"
  @data_sha256 String.duplicate("ab", 32)

  @request %{
    event_id: @event_id,
    source: "/gobusgo/test/oba/agencies-with-coverage",
    time: ~U[2026-10-02 03:15:01Z],
    response: %{
      destination: @destination,
      fetched_at: ~U[2026-10-02 03:15:00Z],
      data_sha256: @data_sha256,
      request_id: @request_id
    }
  }

  describe "dataset/0" do
    test "names the agency discovery dataset" do
      assert StoredEvent.dataset() == "oba/agencies-with-coverage"
    end
  end

  describe "record/1" do
    test "goes to the dataset's event topic under the dataset's constant key" do
      assert Map.take(StoredEvent.record(@request), [:topic, :key, :headers]) == %{
               topic: "oba.agencies-with-coverage.response-stored",
               key: "oba/agencies-with-coverage",
               headers: [{"content-type", "application/cloudevents+json"}]
             }
    end

    test "refers to the stored response as a CloudEvent" do
      assert JSON.decode!(StoredEvent.record(@request).value) == %{
               "specversion" => "1.0",
               "id" => @event_id,
               "source" => "/gobusgo/test/oba/agencies-with-coverage",
               "type" => "gobusgo.response.stored.v1",
               "time" => "2026-10-02T03:15:01Z",
               "subject" => @destination,
               "datacontenttype" => "application/json",
               "partitionkey" => "oba/agencies-with-coverage",
               "data" => %{
                 "dataset" => "oba/agencies-with-coverage",
                 "destination" => @destination,
                 "fetchedAt" => "2026-10-02T03:15:00Z",
                 "dataSha256" => @data_sha256,
                 "requestId" => @request_id
               }
             }
    end

    test "raises for an event identifier that is not a UUID version 7" do
      assert_raise AssertionError, ~r/event identifier/, fn ->
        StoredEvent.record(%{@request | event_id: "event"})
      end
    end
  end
end
