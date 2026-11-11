defmodule Gobusgo.Routing.TripPathRetry do
  @minute_ms 60_000
  @delays_ms [10 * @minute_ms, 30 * @minute_ms]
  @delay_ms_last 60 * @minute_ms

  @moduledoc """
  The schedule on which a date whose trip path build failed is built again:
  #{div(Enum.at(@delays_ms, 0), @minute_ms)} minutes after the first
  failure, #{div(Enum.at(@delays_ms, 1), @minute_ms)} after the second, and
  every #{div(@delay_ms_last, @minute_ms)} minutes after any later one,
  counted from the time of the last failure.

  A state names the SHA-256 of the inputs the failures are of, so a failure
  on other inputs starts the count again. This module is pure: it reads no
  clock and holds no state, and times are values in milliseconds.
  """

  @type state :: %{
          inputs_sha256: binary(),
          failure_count: pos_integer(),
          failed_at_ms: integer()
        }

  @doc "The wait after the `failure_count`th failure, in milliseconds."
  @spec delay_ms(pos_integer()) :: pos_integer()
  def delay_ms(failure_count) when is_integer(failure_count) and failure_count >= 1 do
    Enum.at(@delays_ms, failure_count - 1, @delay_ms_last)
  end

  @doc """
  The state after a failure at `input.failed_at_ms` of the build of
  `input.inputs_sha256`, given `input.previous`, the state before it or
  `:none`.
  """
  @spec after_failure(%{
          previous: :none | state(),
          inputs_sha256: binary(),
          failed_at_ms: integer()
        }) :: state()
  def after_failure(%{previous: :none, inputs_sha256: sha256, failed_at_ms: failed_at_ms}) do
    %{inputs_sha256: sha256, failure_count: 1, failed_at_ms: failed_at_ms}
  end

  def after_failure(%{previous: previous, inputs_sha256: sha256, failed_at_ms: failed_at_ms}) do
    failure_count = previous_count(previous, sha256) + 1
    %{inputs_sha256: sha256, failure_count: failure_count, failed_at_ms: failed_at_ms}
  end

  defp previous_count(%{inputs_sha256: sha256, failure_count: failure_count}, sha256),
    do: failure_count

  defp previous_count(%{}, _sha256), do: 0

  @doc "When the next attempt is due, in milliseconds."
  @spec next_attempt_ms(state()) :: integer()
  def next_attempt_ms(%{failure_count: failure_count, failed_at_ms: failed_at_ms}) do
    failed_at_ms + delay_ms(failure_count)
  end

  @doc "Whether the next attempt is due at `input.now_ms`."
  @spec due?(%{state: state(), now_ms: integer()}) :: boolean()
  def due?(%{state: state, now_ms: now_ms}), do: now_ms >= next_attempt_ms(state)
end
