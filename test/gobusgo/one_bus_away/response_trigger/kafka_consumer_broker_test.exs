defmodule Gobusgo.OneBusAway.ResponseTrigger.KafkaConsumerBrokerTest do
  # Runs the consumer pipeline against a real broker: records are published
  # to an event topic created for the test, consumed by a consumer group of
  # its own, and the dead-letter topic and the processed records are read
  # back. The reader is a double defined here, so no storage is involved.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.ResponseTrigger.KafkaConsumer
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.OneBusAway.RawAgencyResponse.StoredEvent
  alias Gobusgo.Publisher
  alias Gobusgo.Test.KafkaBroker

  @moduletag :kafka
  @moduletag capture_log: true
  @moduletag timeout: 120_000

  defmodule StoredReader do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(destination, options) do
      case Keyword.fetch!(options, :stored) do
        %{^destination => content} -> {:ok, content}
        _other -> {:error, :not_found}
      end
    end

    @impl Gobusgo.Reader
    def discover(_request, _options), do: {:ok, %{destinations: [], cursor: nil}}
  end

  defmodule ForwardingPublisher do
    @behaviour Gobusgo.Publisher

    # Dead-letter records go to the broker; processed records, whose topic
    # is fixed, are reported to the test.
    @impl Gobusgo.Publisher
    def publish([%{topic: topic} | _rest] = records, options) do
      if String.ends_with?(topic, ".dead-letter") do
        Publisher.Kafka.publish(records, client: Keyword.fetch!(options, :client))
      else
        send(Keyword.fetch!(options, :recipient), {:processed, records})
        :ok
      end
    end
  end

  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"

  defp raw do
    data = %{
      "limitExceeded" => false,
      "list" => [
        %{"agencyId" => "1", "lat" => 47.5, "lon" => -122.25, "latSpan" => 0.5, "lonSpan" => 0.75}
      ],
      "references" => %{
        "agencies" => [
          %{
            "id" => "1",
            "name" => "Metro Transit",
            "url" => "https://agency.example.test",
            "timezone" => "America/Los_Angeles"
          }
        ]
      }
    }

    response = %{
      agencies: [],
      envelope: %{
        "code" => 200,
        "currentTime" => 1_710_953_797_130,
        "data" => data,
        "text" => "OK",
        "version" => 2
      },
      fetched_at: ~U[2026-10-02 03:15:00Z],
      host: "oba.example.test",
      http_status: 200,
      method: "GET"
    }

    RawAgencyResponse.build(%{response: response, request_id: @request_id})
  end

  defp event_value(raw) do
    StoredEvent.record(%{
      event_id: Gobusgo.RequestId.generate(),
      source: "/gobusgo/test/oba/agencies-with-coverage",
      time: ~U[2026-10-02 03:15:01Z],
      response: %{
        destination: raw.destination,
        fetched_at: raw.fetched_at,
        data_sha256: raw.data_sha256,
        request_id: @request_id
      }
    }).value
  end

  defp await_messages(topic, count, tries_left \\ 120) do
    messages = KafkaBroker.messages(topic)

    cond do
      length(messages) >= count ->
        messages

      tries_left == 0 ->
        flunk("expected #{count} records on #{topic}, found #{length(messages)}")

      true ->
        Process.sleep(500)
        await_messages(topic, count, tries_left - 1)
    end
  end

  setup do
    client = KafkaBroker.start_client()
    topic = KafkaBroker.create_topic("events")
    dead_letter_topic = KafkaBroker.create_topic_named(topic <> ".dead-letter")
    group = "test-group-#{System.unique_integer([:positive])}-#{System.os_time(:millisecond)}"
    stored = raw()

    start_supervised!(
      {KafkaConsumer,
       event: Gobusgo.OneBusAway.RawAgencyResponse.StoredEvent,
       processor: Gobusgo.OneBusAway.AgencyBatch,
       name: Module.concat(__MODULE__, "Consumer#{System.unique_integer([:positive])}"),
       producer:
         KafkaConsumer.producer(%{
           endpoints: KafkaBroker.endpoints(),
           consumer_group: group,
           topic: topic
         }),
       consumer_group: group,
       task_supervisor: start_supervised!(Task.Supervisor),
       retry_delay_ms_base: 1,
       read_options: [
         backend: StoredReader,
         stored: %{stored.destination => Gobusgo.Compression.compress(stored.content)}
       ],
       publish_options: [backend: ForwardingPublisher, client: client, recipient: self()]}
    )

    %{
      client: client,
      topic: topic,
      dead_letter_topic: dead_letter_topic,
      group: group,
      stored: stored
    }
  end

  defp publish_events(context, values) do
    records =
      for value <- values, do: %{topic: context.topic, key: "k", value: value, headers: []}

    :ok = Publisher.publish(records, backend: Publisher.Kafka, client: context.client)
  end

  test "processes the stored response a consumed event names", context do
    publish_events(context, [event_value(context.stored)])

    assert_receive {:processed, [%{key: "agency/1"}]}, 60_000
    assert_receive {:processed, [%{key: "manifest"}]}, 60_000
    assert KafkaBroker.messages(context.dead_letter_topic) == []
  end

  test "dead-letters the records it gives up on and goes on to the next", context do
    missing = %{context.stored | destination: context.stored.destination <> ".gone"}
    publish_events(context, ["<html>", event_value(missing), event_value(context.stored)])

    assert_receive {:processed, [%{key: "manifest"}]}, 60_000

    assert [not_json, not_found] = await_messages(context.dead_letter_topic, 2)
    assert not_json.value == "<html>"
    assert not_json.key == "k"

    topic = context.topic
    group = context.group

    assert %{
             "ERROR_CODE" => "INVALID_JSON",
             "ORIGINAL_TOPIC" => ^topic,
             "ORIGINAL_OFFSET" => "0",
             "CONSUMER_GROUP" => ^group
           } = Map.new(not_json.headers)

    assert %{"ERROR_CODE" => "READ_FAILURE", "ORIGINAL_OFFSET" => "1", "RETRY_ATTEMPTS" => "1"} =
             Map.new(not_found.headers)
  end
end
