defmodule Gobusgo.Publisher.InProcessTest do
  # Publishes through Gobusgo.Publisher with the in-process backend and
  # subscribers defined here, so delivery, ordering, and each failure are
  # observed through the publisher contract.
  use ExUnit.Case, async: true

  alias Gobusgo.Publisher
  alias Gobusgo.Publisher.InProcess

  defmodule Subscriber do
    def receive_values(recipient, topic, values) do
      send(recipient, {:delivered, topic, values})
      :ok
    end

    def exit_with(reason, _values), do: exit(reason)
  end

  defp record(topic, value), do: %{topic: topic, key: "key", value: value, headers: []}

  defp publish(records, subscribers) do
    Publisher.publish(records, backend: InProcess, subscribers: subscribers)
  end

  defp subscriber(topic), do: {Subscriber, :receive_values, [self(), topic]}

  test "delivers the values of a topic to its subscriber in order" do
    records = [record("a", "1"), record("a", "2")]

    assert publish(records, %{"a" => subscriber("a")}) == :ok
    assert_received {:delivered, "a", ["1", "2"]}
  end

  test "delivers each run of records to the subscriber of its topic, in publish order" do
    records = [record("a", "1"), record("b", "2"), record("a", "3")]

    assert publish(records, %{"a" => subscriber("a"), "b" => subscriber("b")}) == :ok

    assert {:messages,
            [{:delivered, "a", ["1"]}, {:delivered, "b", ["2"]}, {:delivered, "a", ["3"]}]} =
             Process.info(self(), :messages)
  end

  test "returns unknown_topic for a topic without a subscriber and stops there" do
    records = [record("a", "1"), record("nowhere", "2"), record("a", "3")]

    assert publish(records, %{"a" => subscriber("a")}) == {:error, :unknown_topic}
    assert_received {:delivered, "a", ["1"]}
    refute_received {:delivered, "a", ["3"]}
  end

  test "returns timeout when the subscriber does not answer in time" do
    subscribers = %{"a" => {Subscriber, :exit_with, [{:timeout, {GenServer, :call, []}}]}}

    assert publish([record("a", "1")], subscribers) == {:error, :timeout}
  end

  test "returns unavailable when the subscriber is not running" do
    subscribers = %{"a" => {Subscriber, :exit_with, [{:noproc, {GenServer, :call, []}}]}}

    assert publish([record("a", "1")], subscribers) == {:error, :unavailable}
  end
end
