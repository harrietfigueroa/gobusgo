defmodule Gobusgo.Publisher.KafkaTest do
  # Publishes through Gobusgo.Publisher with the Kafka backend. The cases
  # tagged :kafka run against a real broker and read the topic back; the
  # others need no broker.
  use ExUnit.Case, async: true

  alias Gobusgo.Publisher
  alias Gobusgo.Publisher.Kafka
  alias Gobusgo.Test.KafkaBroker

  defp record(topic, key, value) do
    %{topic: topic, key: key, value: value, headers: [{"content-type", "text/plain"}]}
  end

  defp publish(records, options) do
    Publisher.publish(records, Keyword.merge([backend: Kafka], options))
  end

  describe "publish/2 without a broker" do
    test "returns unavailable when the client is not running" do
      assert publish([record("any", "k", "v")], client: :gobusgo_no_such_client) ==
               {:error, :unavailable}
    end

    test "returns record_too_large for a record over the size limit, before sending" do
      value = :binary.copy("x", 1_000_001)

      assert publish([record("any", "k", value)], client: :gobusgo_no_such_client) ==
               {:error, :record_too_large}
    end
  end

  describe "publish/2 against a broker" do
    @describetag :kafka

    setup do
      %{client: KafkaBroker.start_client()}
    end

    test "stores the key, the value, and the headers of every record", %{client: client} do
      topic = KafkaBroker.create_topic("publisher")

      assert publish([record(topic, "a", "1"), record(topic, "b", "2")], client: client) == :ok

      assert Enum.sort(
               for message <- KafkaBroker.messages(topic), do: Map.delete(message, :offset)
             ) ==
               [
                 %{key: "a", value: "1", headers: [{"content-type", "text/plain"}]},
                 %{key: "b", value: "2", headers: [{"content-type", "text/plain"}]}
               ]
    end

    test "keeps the records of one key in publish order", %{client: client} do
      topic = KafkaBroker.create_topic("publisher")
      values = for index <- 1..200, do: Integer.to_string(index)

      assert publish(for(value <- values, do: record(topic, "one-key", value)), client: client) ==
               :ok

      assert for(message <- KafkaBroker.messages(topic), do: message.value) == values
    end

    test "publishes to several topics in one call", %{client: client} do
      first = KafkaBroker.create_topic("publisher")
      second = KafkaBroker.create_topic("publisher")

      assert publish([record(first, "k", "1"), record(second, "k", "2")], client: client) == :ok

      assert [%{value: "1"}] = KafkaBroker.messages(first)
      assert [%{value: "2"}] = KafkaBroker.messages(second)
    end

    test "returns unknown_topic for a topic the broker does not have", %{client: client} do
      assert publish([record("test.never-created", "k", "v")], client: client) ==
               {:error, :unknown_topic}
    end
  end
end
