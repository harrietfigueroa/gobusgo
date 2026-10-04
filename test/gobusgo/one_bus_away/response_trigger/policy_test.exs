defmodule Gobusgo.OneBusAway.ResponseTrigger.PolicyTest do
  # Verifies the retry and dead-letter rules as pure functions: each outcome
  # of an attempt is paired with the decision it must produce.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.ResponseTrigger.Policy

  defp failure(class, error_code) do
    {:error, %{class: class, error_code: error_code, stage: :read, reason: :io_failure}}
  end

  describe "attempt_count_max/0" do
    test "allows three attempts" do
      assert Policy.attempt_count_max() == 3
    end
  end

  describe "next/1" do
    test "finishes on a published response, whatever the attempt" do
      for attempt_count <- 1..3 do
        assert Policy.next(%{attempt_count: attempt_count, outcome: {:ok, %{}}}) == :finished
      end
    end

    for {name, outcome} <- [
          {"a transient failure", {:error, %{class: :transient, error_code: "READ_FAILURE"}}},
          {"an attempt past its deadline", :deadline_exceeded},
          {"a crashed attempt", :crashed}
        ] do
      test "retries #{name} while attempts remain" do
        outcome = unquote(Macro.escape(outcome))

        assert Policy.next(%{attempt_count: 1, outcome: outcome}) == :retry
        assert Policy.next(%{attempt_count: 2, outcome: outcome}) == :retry
      end
    end

    for {name, outcome, error_code} <- [
          {"a transient failure", {:error, %{class: :transient, error_code: "WRITE_FAILURE"}},
           "WRITE_FAILURE"},
          {"an attempt past its deadline", :deadline_exceeded, "TIMEOUT"},
          {"a crashed attempt", :crashed, "INTERNAL_ERROR"}
        ] do
      test "dead-letters #{name} as exhausted on the last attempt" do
        assert {:dead_letter, failure} =
                 Policy.next(%{attempt_count: 3, outcome: unquote(Macro.escape(outcome))})

        assert %{error_code: unquote(error_code), attempt_count: 3, retries_exhausted: true} =
                 failure
      end
    end

    test "dead-letters a permanent failure at once, without the exhausted mark" do
      assert {:dead_letter, failure} =
               Policy.next(%{attempt_count: 1, outcome: failure(:permanent, "HASH_MISMATCH")})

      assert %{error_code: "HASH_MISMATCH", attempt_count: 1, retries_exhausted: false} = failure
    end

    test "writes one sentence for every error code, with no reason in it" do
      for error_code <- [
            "READ_FAILURE",
            "WRITE_FAILURE",
            "INVALID_JSON",
            "SCHEMA_MISMATCH",
            "HASH_MISMATCH",
            "DESTINATION_MISMATCH"
          ] do
        assert {:dead_letter, %{error_message: message}} =
                 Policy.next(%{attempt_count: 1, outcome: failure(:permanent, error_code)})

        assert message =~ ~r/^[A-Z][^.]*\.$/
        refute message =~ "io_failure"
      end
    end
  end

  describe "rejection/1" do
    for {reason, error_code} <- [
          invalid_json: "INVALID_JSON",
          schema_mismatch: "SCHEMA_MISMATCH",
          unsupported_type: "UNSUPPORTED_TYPE"
        ] do
      test "dead-letters an event that fails as #{reason} without retrying" do
        assert %{
                 error_code: unquote(error_code),
                 attempt_count: 1,
                 retries_exhausted: false,
                 error_message: message
               } = Policy.rejection(unquote(reason))

        assert message =~ ~r/^[A-Z][^.]*\.$/
      end
    end
  end

  describe "retry_delay_ms/1" do
    test "doubles the window per attempt and scales it by the jitter" do
      assert Policy.retry_delay_ms(%{attempt_count: 1, delay_ms_base: 500, jitter: 1.0}) == 500
      assert Policy.retry_delay_ms(%{attempt_count: 2, delay_ms_base: 500, jitter: 1.0}) == 1000
      assert Policy.retry_delay_ms(%{attempt_count: 2, delay_ms_base: 500, jitter: 0.5}) == 500
      assert Policy.retry_delay_ms(%{attempt_count: 1, delay_ms_base: 500, jitter: 0.0}) == 0
    end

    test "keeps the delays of a full run of attempts within two seconds" do
      delays =
        for attempt_count <- 1..(Policy.attempt_count_max() - 1) do
          Policy.retry_delay_ms(%{
            attempt_count: attempt_count,
            delay_ms_base: Policy.retry_delay_ms_base(),
            jitter: 1.0
          })
        end

      assert Enum.sum(delays) <= 2_000
    end
  end
end
