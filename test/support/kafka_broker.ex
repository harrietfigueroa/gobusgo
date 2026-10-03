defmodule Gobusgo.Test.KafkaBroker do
  @moduledoc """
  Helpers for tests tagged `:kafka`, which talk to a real broker named by
  `GOBUSGO_TEST_KAFKA_BOOTSTRAP_SERVERS` (`localhost:9092` when unset). Each
  test gets topics of its own, created here and deleted when it exits.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @client :gobusgo_test_kafka
  @partition_count 3
  @timeout_ms 10_000

  def client, do: @client

  def endpoints do
    text = System.get_env("GOBUSGO_TEST_KAFKA_BOOTSTRAP_SERVERS") || "localhost:9092"
    {:ok, %{endpoints: endpoints}} = Gobusgo.Config.fetch_kafka(bootstrap_servers: text)
    endpoints
  end

  def start_client do
    :ok = Gobusgo.Kafka.Client.start(%{client: @client, endpoints: endpoints()})
    @client
  end

  @doc "Creates a topic with a name no other test uses and returns the name."
  def create_topic(label) do
    create_topic_named(
      "test.#{label}.#{System.unique_integer([:positive])}.#{System.os_time(:millisecond)}"
    )
  end

  @doc "Creates the topic `topic`, deleted when the test exits, and returns the name."
  def create_topic_named(topic) do
    specification = %{
      name: topic,
      num_partitions: @partition_count,
      replication_factor: 1,
      assignments: [],
      configs: []
    }

    :ok = :brod.create_topics(endpoints(), [specification], %{timeout: @timeout_ms})
    on_exit(fn -> :brod.delete_topics(endpoints(), [topic], @timeout_ms) end)
    await_topic(topic, 50)
    topic
  end

  @doc "Every message of `topic`, as `%{key, value, headers}`, in partition then offset order."
  def messages(topic) do
    for partition <- 0..(@partition_count - 1),
        message <- fetch_all(topic, partition, 0) do
      message
    end
  end

  defp fetch_all(topic, partition, offset) do
    {:ok, latest} = :brod.resolve_offset(endpoints(), topic, partition, :latest)

    if offset >= latest do
      []
    else
      {:ok, {_high_watermark, messages}} = :brod.fetch(endpoints(), topic, partition, offset)

      fetched =
        for {:kafka_message, message_offset, key, value, _operation, _time, headers} <- messages do
          %{offset: message_offset, key: key, value: value, headers: headers}
        end

      fetched ++ fetch_all(topic, partition, List.last(fetched).offset + 1)
    end
  end

  defp await_topic(topic, tries_left) when tries_left > 0 do
    case :brod.resolve_offset(endpoints(), topic, @partition_count - 1, :latest) do
      {:ok, _offset} ->
        :ok

      {:error, _reason} ->
        Process.sleep(100)
        await_topic(topic, tries_left - 1)
    end
  end
end
