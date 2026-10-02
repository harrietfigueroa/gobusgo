defmodule Gobusgo.OneBusAway.AgencyTrigger.KafkaConsumerTest do
  # Runs the consumer pipeline on Broadway's dummy producer, so messages are
  # pushed in by the test and their acknowledgement is observed with no
  # broker. The reader and the publisher are doubles defined here.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.AgencyTrigger.KafkaConsumer

  @moduletag capture_log: true

  defmodule MissingReader do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(_destination, _options), do: {:error, :not_found}

    @impl Gobusgo.Reader
    def discover(_request, _options), do: {:ok, %{destinations: [], cursor: nil}}
  end

  defmodule ScriptedPublisher do
    @behaviour Gobusgo.Publisher

    @impl Gobusgo.Publisher
    def publish(records, options) do
      send(Keyword.fetch!(options, :recipient), {:published, records})
      Keyword.fetch!(options, :result)
    end
  end

  @topic "oba.agencies-with-coverage.response-stored"
  @metadata %{topic: @topic, partition: 3, offset: 9, key: "the key", headers: [{"h", "v"}]}

  defp start_consumer(publish_result) do
    name = Module.concat(__MODULE__, "Consumer#{System.unique_integer([:positive])}")
    task_supervisor = start_supervised!(Task.Supervisor)

    start_supervised!(
      {KafkaConsumer,
       name: name,
       producer: {Broadway.DummyProducer, []},
       consumer_group: "test-group",
       task_supervisor: task_supervisor,
       retry_delay_ms_base: 1,
       read_options: [backend: MissingReader],
       publish_options: [backend: ScriptedPublisher, recipient: self(), result: publish_result]}
    )

    name
  end

  test "acknowledges a record it dead-letters, with the position it was consumed at" do
    name = start_consumer(:ok)

    reference = Broadway.test_message(name, "not an event", metadata: @metadata)

    assert_receive {:ack, ^reference, [_successful], []}, 2_000
    assert_received {:published, [record]}

    assert %{topic: @topic <> ".dead-letter", key: "the key", value: "not an event"} = record

    assert %{
             "h" => "v",
             "ORIGINAL_PARTITION" => "3",
             "ORIGINAL_OFFSET" => "9",
             "CONSUMER_GROUP" => "test-group"
           } = Map.new(record.headers)
  end

  test "does not acknowledge a record whose dead-letter record is not published" do
    name = start_consumer({:error, :unavailable})

    reference = Broadway.test_message(name, "not an event", metadata: @metadata)

    assert_receive {:published, [_record]}, 2_000
    refute_receive {:ack, ^reference, _successful, _failed}, 500
  end
end
