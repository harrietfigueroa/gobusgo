defmodule Gobusgo.Routing.TripPathRetryTest do
  # Drives the retry schedule with failure counts and times given as values:
  # the delay after each count, when the next attempt is due, and how a
  # failure on changed inputs starts the count again.
  use ExUnit.Case, async: true

  alias Gobusgo.Routing.TripPathRetry

  @minute_ms 60_000
  @first_failed_at_ms 1_000_000
  @inputs_sha256 :crypto.hash(:sha256, "inputs")
  @other_inputs_sha256 :crypto.hash(:sha256, "other inputs")

  defp fail_times(count, inputs_sha256) do
    Enum.reduce(1..count, :none, fn index, previous ->
      TripPathRetry.after_failure(%{
        previous: previous,
        inputs_sha256: inputs_sha256,
        failed_at_ms: @first_failed_at_ms + index * 1_000
      })
    end)
  end

  describe "delay_ms/1" do
    test "is 10 minutes after the first failure, 30 after the second, then hourly" do
      assert Enum.map([1, 2, 3, 5, 40], &TripPathRetry.delay_ms/1) ==
               Enum.map([10, 30, 60, 60, 60], &(&1 * @minute_ms))
    end
  end

  describe "after_failure/1" do
    test "counts the failures of the same inputs" do
      assert %{failure_count: 5} = fail_times(5, @inputs_sha256)
    end

    test "starts at one again when the inputs changed" do
      previous = fail_times(5, @inputs_sha256)

      assert %{failure_count: 1, inputs_sha256: @other_inputs_sha256} =
               TripPathRetry.after_failure(%{
                 previous: previous,
                 inputs_sha256: @other_inputs_sha256,
                 failed_at_ms: @first_failed_at_ms
               })
    end
  end

  describe "next_attempt_ms/1" do
    test "follows the last failure by the delay of the count, after 1, 2, and 5 failures" do
      for {count, delay_minutes} <- [{1, 10}, {2, 30}, {5, 60}] do
        state = fail_times(count, @inputs_sha256)

        assert TripPathRetry.next_attempt_ms(state) ==
                 @first_failed_at_ms + count * 1_000 + delay_minutes * @minute_ms
      end
    end
  end

  describe "due?/1" do
    test "is false before the next attempt and true from it" do
      state = fail_times(1, @inputs_sha256)
      next_ms = TripPathRetry.next_attempt_ms(state)

      assert [false, true, true] ==
               Enum.map(
                 [next_ms - 1, next_ms, next_ms + 1],
                 &TripPathRetry.due?(%{state: state, now_ms: &1})
               )
    end
  end
end
