defmodule Gobusgo.Kafka.TopicSubscriberTest do
  # Starts the subscriber with a subscriber function that reports to the
  # test. The cases tagged :kafka publish to a real broker first and observe
  # what the function receives; the other needs no broker.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.Kafka.TopicSubscriber
  alias Gobusgo.Publisher
  alias Gobusgo.Test.KafkaBroker

  defmodule Recipient do
    def deliver(recipient, values) do
      send(recipient, {:values, values})
      :ok
    end
  end

  defp start_subscriber(options) do
    name = Module.concat(__MODULE__, "Subscriber#{System.unique_integer([:positive])}")

    defaults = [name: name, subscriber: {Recipient, :deliver, [self()]}, restart_delay_ms: 50]
    start_supervised!({TopicSubscriber, Keyword.merge(defaults, options)})
  end

  defp receive_values(count, received \\ []) do
    if length(received) >= count do
      received
    else
      assert_receive {:values, values}, 10_000
      receive_values(count, received ++ values)
    end
  end

  describe "without a broker" do
    test "stays up, retries, and logs the first stop once while its client is not running" do
      log =
        capture_log(fn ->
          subscriber = start_subscriber(client: :gobusgo_no_such_client, topic: "any")
          Process.sleep(300)
          assert Process.alive?(subscriber)
        end)

      assert length(String.split(log, "Kafka topic subscriber stopped")) == 2
    end
  end

  describe "against a broker" do
    @describetag :kafka

    setup do
      %{client: KafkaBroker.start_client()}
    end

    defp publish(topic, pairs, client) do
      records =
        for {key, value} <- pairs, do: %{topic: topic, key: key, value: value, headers: []}

      :ok = Publisher.publish(records, backend: Publisher.Kafka, client: client)
    end

    test "delivers the values stored before it started", %{client: client} do
      topic = KafkaBroker.create_topic("subscriber")
      publish(topic, [{"a", "1"}, {"b", "2"}, {"c", "3"}], client)

      start_subscriber(client: client, topic: topic)

      assert Enum.sort(receive_values(3)) == ["1", "2", "3"]
    end

    test "delivers the values of one key in order, old and new", %{client: client} do
      topic = KafkaBroker.create_topic("subscriber")
      publish(topic, [{"k", "1"}, {"k", "2"}], client)

      start_subscriber(client: client, topic: topic)
      assert receive_values(2) == ["1", "2"]

      publish(topic, [{"k", "3"}], client)
      assert receive_values(1) == ["3"]
    end

    test "delivers at most value_count_max values per call", %{client: client} do
      topic = KafkaBroker.create_topic("subscriber")
      publish(topic, for(index <- 1..5, do: {"k", Integer.to_string(index)}), client)

      start_subscriber(client: client, topic: topic, value_count_max: 2)

      assert_receive {:values, ["1", "2"]}, 10_000
      assert_receive {:values, ["3", "4"]}, 10_000
      assert_receive {:values, ["5"]}, 10_000
    end

    test "reads from the earliest record again after its reader stops", %{client: client} do
      topic = KafkaBroker.create_topic("subscriber")
      publish(topic, [{"k", "1"}], client)

      subscriber = start_subscriber(client: client, topic: topic)
      assert receive_values(1) == ["1"]

      %{reader: reader} = :sys.get_state(subscriber)
      capture_log(fn -> Process.exit(reader, :kill) end)

      assert receive_values(1) == ["1"]
    end
  end
end
