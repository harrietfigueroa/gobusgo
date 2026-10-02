defmodule Gobusgo.CloudEventTest do
  # Verifies the structured-mode encoding as a pure function of the event:
  # expected documents are written out by hand, so the encoder is checked
  # against literals and never against itself.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.CloudEvent

  @event %{
    id: "event-1",
    source: "/gobusgo/test",
    type: "gobusgo.sample.created.v1",
    time: ~U[2026-10-02 03:15:00Z],
    subject: "sample",
    partition_key: "sample/1",
    data: %{"b" => 1, "a" => "x"}
  }

  describe "type/1" do
    test "joins the prefix, the name, and the version" do
      assert CloudEvent.type(%{name: "sample.created", version: 2}) ==
               "gobusgo.sample.created.v2"
    end

    for {description, type, pattern} <- [
          {"an empty name", %{name: "", version: 1}, ~r/name/},
          {"a version of zero", %{name: "sample.created", version: 0}, ~r/version/}
        ] do
      test "raises for #{description}" do
        assert_raise AssertionError, unquote(Macro.escape(pattern)), fn ->
          CloudEvent.type(unquote(Macro.escape(type)))
        end
      end
    end
  end

  describe "encode/1" do
    test "is one compact JSON document with sorted keys" do
      assert CloudEvent.encode(@event) ==
               ~s({"data":{"a":"x","b":1},"datacontenttype":"application/json",) <>
                 ~s("id":"event-1","partitionkey":"sample/1","source":"/gobusgo/test",) <>
                 ~s("specversion":"1.0","subject":"sample","time":"2026-10-02T03:15:00Z",) <>
                 ~s("type":"gobusgo.sample.created.v1"})
    end

    for {description, change, pattern} <- [
          {"an empty id", %{id: ""}, ~r/id/},
          {"an empty subject", %{subject: ""}, ~r/subject/},
          {"an empty partition key", %{partition_key: ""}, ~r/partition_key/},
          {"a source that is not a path", %{source: "gobusgo"}, ~r/source/},
          {"a type without the prefix", %{type: "sample.created.v1"}, ~r/type/},
          {"data that is not a map", %{data: [1]}, ~r/data/}
        ] do
      test "raises for #{description}" do
        event = Map.merge(@event, unquote(Macro.escape(change)))

        assert_raise AssertionError, unquote(Macro.escape(pattern)), fn ->
          CloudEvent.encode(event)
        end
      end
    end

    test "raises for a time outside UTC" do
      paris = %{@event.time | utc_offset: 3600, time_zone: "Europe/Paris", zone_abbr: "CET"}

      assert_raise AssertionError, ~r/UTC/, fn -> CloudEvent.encode(%{@event | time: paris}) end
    end
  end

  describe "record/2" do
    test "is the encoded event keyed by its partition key, with the media type header" do
      assert CloudEvent.record("sample.topic", @event) == %{
               topic: "sample.topic",
               key: "sample/1",
               value: CloudEvent.encode(@event),
               headers: [{"content-type", "application/cloudevents+json"}]
             }
    end
  end

  describe "decode/1" do
    test "returns the event an encoded document holds" do
      assert CloudEvent.decode(CloudEvent.encode(@event)) == {:ok, @event}
    end

    test "ignores attributes it does not know" do
      document =
        @event |> CloudEvent.encode() |> JSON.decode!() |> Map.put("extra", 1) |> JSON.encode!()

      assert CloudEvent.decode(document) == {:ok, @event}
    end

    test "returns invalid_json for a document that is not JSON" do
      assert CloudEvent.decode("{not json") == {:error, :invalid_json}
    end

    for {description, change} <- [
          {"a document that is not an object", quote(do: fn _document -> [1] end)},
          {"a missing id", quote(do: &Map.delete(&1, "id"))},
          {"another specification version", quote(do: &Map.put(&1, "specversion", "0.3"))},
          {"another data content type", quote(do: &Map.put(&1, "datacontenttype", "text/xml"))},
          {"data that is not an object", quote(do: &Map.put(&1, "data", "text"))},
          {"a time that is not a time", quote(do: &Map.put(&1, "time", "yesterday"))}
        ] do
      test "returns schema_mismatch for #{description}" do
        document =
          @event |> CloudEvent.encode() |> JSON.decode!() |> unquote(change).() |> JSON.encode!()

        assert CloudEvent.decode(document) == {:error, :schema_mismatch}
      end
    end
  end
end
