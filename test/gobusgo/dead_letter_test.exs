defmodule Gobusgo.DeadLetterTest do
  # Verifies the dead-letter record as a pure function of the consumed
  # record and its failure: each expected record is written out by hand.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.DeadLetter

  @request %{
    consumed: %{
      topic: "oba.agencies-with-coverage.response-stored",
      partition: 7,
      offset: 42,
      key: "oba/agencies-with-coverage",
      value: "not even json",
      headers: [{"content-type", "application/cloudevents+json"}]
    },
    consumer_group: "gobusgo.agency-processor",
    failure: %{
      error_code: "READ_FAILURE",
      error_message: "The stored response could not be read.",
      attempt_count: 3,
      retries_exhausted: true
    },
    first_attempt_at: ~U[2026-10-02 03:15:01.250Z],
    last_attempt_at: ~U[2026-10-02 03:15:03.000Z]
  }

  describe "topic/1" do
    test "names the dead-letter topic of a topic" do
      assert DeadLetter.topic("oba.agencies-with-coverage.response-stored") ==
               "oba.agencies-with-coverage.response-stored.dead-letter"
    end
  end

  describe "record/1" do
    test "keeps the key and the value as consumed, on the dead-letter topic" do
      assert Map.take(DeadLetter.record(@request), [:topic, :key, :value]) == %{
               topic: "oba.agencies-with-coverage.response-stored.dead-letter",
               key: "oba/agencies-with-coverage",
               value: "not even json"
             }
    end

    test "describes a failure that ran out of retries in headers after the consumed ones" do
      assert DeadLetter.record(@request).headers == [
               {"content-type", "application/cloudevents+json"},
               {"ERROR_CODE", "READ_FAILURE"},
               {"ERROR_MESSAGE", "The stored response could not be read."},
               {"RETRY_ATTEMPTS", "3"},
               {"EXHAUSTED_RETRY_CONDITION", "MaximumRetryAttempts"},
               {"ORIGINAL_TOPIC", "oba.agencies-with-coverage.response-stored"},
               {"ORIGINAL_PARTITION", "7"},
               {"ORIGINAL_OFFSET", "42"},
               {"CONSUMER_GROUP", "gobusgo.agency-processor"},
               {"FIRST_ATTEMPT_TIME", "2026-10-02T03:15:01.250Z"},
               {"LAST_ATTEMPT_TIME", "2026-10-02T03:15:03.000Z"}
             ]
    end

    test "leaves the exhausted-retry header out for a failure sent without retrying" do
      failure = %{@request.failure | attempt_count: 1, retries_exhausted: false}

      names =
        for {name, _text} <- DeadLetter.record(%{@request | failure: failure}).headers, do: name

      refute "EXHAUSTED_RETRY_CONDITION" in names
      assert "RETRY_ATTEMPTS" in names
    end

    test "replaces the failure headers of a record that was dead-lettered before" do
      consumed = %{@request.consumed | headers: [{"ERROR_CODE", "TIMEOUT"}, {"other", "kept"}]}
      headers = DeadLetter.record(%{@request | consumed: consumed}).headers

      assert for({"ERROR_CODE", text} <- headers, do: text) == ["READ_FAILURE"]
      assert {"other", "kept"} in headers
    end

    for {name, change} <- [
          {"an attempt count below one", [:failure, :attempt_count]},
          {"a negative offset", [:consumed, :offset]}
        ] do
      test "raises for #{name}" do
        assert_raise AssertionError, fn ->
          DeadLetter.record(put_in(@request, unquote(change), -1))
        end
      end
    end

    test "raises for a time outside UTC" do
      time = DateTime.shift_zone!(~U[2026-10-02 03:15:01Z], "Etc/UTC") |> Map.put(:time_zone, "X")

      assert_raise AssertionError, ~r/UTC/, fn ->
        DeadLetter.record(%{@request | first_attempt_at: time})
      end
    end
  end
end
