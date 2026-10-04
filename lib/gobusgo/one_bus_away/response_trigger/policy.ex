defmodule Gobusgo.OneBusAway.ResponseTrigger.Policy do
  @attempt_count_max 3
  @retry_delay_ms_base 500

  @moduledoc """
  The rules that decide what follows an attempt to process a "response
  stored" event: finish, retry in place, or dead-letter. Everything here is
  pure.

  An event gets at most #{@attempt_count_max} attempts. A failure the
  processor classes as transient, an attempt past its deadline, and a
  crashed attempt are retried while attempts remain and dead-lettered as
  exhausted after the last one. A permanent failure and an event that is not
  a "response stored" event are dead-lettered at once.

  The delay before attempt `n + 1` is drawn from a window of
  `delay_ms_base * 2^(n - 1)` milliseconds, so the delays of a full run stay
  within #{@retry_delay_ms_base * (Integer.pow(2, @attempt_count_max - 1) - 1)} ms at the
  base of #{@retry_delay_ms_base} ms.
  """

  alias Gobusgo.Assert
  alias Gobusgo.DeadLetter
  alias Gobusgo.OneBusAway.BatchFailure
  alias Gobusgo.OneBusAway.StoredEvent

  @type outcome ::
          {:ok, map()}
          | {:error, BatchFailure.t()}
          | :deadline_exceeded
          | :crashed

  @type decision :: :finished | :retry | {:dead_letter, DeadLetter.failure()}

  @deadline_error_code "TIMEOUT"
  @crash_error_code "INTERNAL_ERROR"

  @error_messages %{
    "READ_FAILURE" => "The stored response could not be read.",
    "WRITE_FAILURE" => "The processed records could not be published.",
    "INVALID_JSON" => "The stored response is not JSON.",
    "SCHEMA_MISMATCH" => "The stored response does not match its schema.",
    "HASH_MISMATCH" => "The stored response does not match its data hash.",
    "DESTINATION_MISMATCH" => "The stored response names another destination.",
    @deadline_error_code => "Processing did not finish within its deadline.",
    @crash_error_code => "Processing crashed."
  }

  @rejections %{
    invalid_json: {"INVALID_JSON", "The event is not JSON."},
    schema_mismatch: {"SCHEMA_MISMATCH", "The event does not match its schema."},
    unsupported_type: {"UNSUPPORTED_TYPE", "The event has a type this consumer does not support."}
  }

  @doc "Attempts allowed for one event."
  @spec attempt_count_max() :: pos_integer()
  def attempt_count_max, do: @attempt_count_max

  @doc "The window, in milliseconds, of the delay after the first attempt."
  @spec retry_delay_ms_base() :: pos_integer()
  def retry_delay_ms_base, do: @retry_delay_ms_base

  @doc "Decides what follows attempt number `attempt_count`, which ended as `outcome`."
  @spec next(%{attempt_count: pos_integer(), outcome: outcome()}) :: decision()
  def next(%{attempt_count: attempt_count, outcome: outcome}) do
    Assert.condition(
      attempt_count >= 1,
      "attempt_count must be at least 1, got: #{attempt_count}"
    )

    Assert.condition(
      attempt_count <= @attempt_count_max,
      "attempt_count must be at most #{@attempt_count_max}, got: #{attempt_count}"
    )

    case outcome do
      {:ok, _result} -> :finished
      {:error, %{class: :permanent, error_code: code}} -> dead_letter(code, attempt_count, false)
      {:error, %{class: :transient, error_code: code}} -> retry(code, attempt_count)
      :deadline_exceeded -> retry(@deadline_error_code, attempt_count)
      :crashed -> retry(@crash_error_code, attempt_count)
      other -> Assert.unreachable(other)
    end
  end

  @doc "The failure of an event that its dataset's event module rejects with `reason`."
  @spec rejection(StoredEvent.decode_error()) :: DeadLetter.failure()
  def rejection(reason) do
    {error_code, error_message} = Map.fetch!(@rejections, reason)

    %{
      error_code: error_code,
      error_message: error_message,
      attempt_count: 1,
      retries_exhausted: false
    }
  end

  @doc """
  The delay in milliseconds after attempt number `attempt_count`, for a
  `jitter` between 0 and 1.
  """
  @spec retry_delay_ms(%{
          attempt_count: pos_integer(),
          delay_ms_base: pos_integer(),
          jitter: float()
        }) ::
          non_neg_integer()
  def retry_delay_ms(%{
        attempt_count: attempt_count,
        delay_ms_base: delay_ms_base,
        jitter: jitter
      }) do
    Assert.condition(
      attempt_count >= 1,
      "attempt_count must be at least 1, got: #{attempt_count}"
    )

    Assert.condition(
      delay_ms_base >= 1,
      "delay_ms_base must be at least 1, got: #{delay_ms_base}"
    )

    Assert.condition(jitter >= 0.0, "jitter must be at least 0, got: #{jitter}")
    Assert.condition(jitter <= 1.0, "jitter must be at most 1, got: #{jitter}")

    window_ms = delay_ms_base * Integer.pow(2, attempt_count - 1)
    trunc(window_ms * jitter)
  end

  defp retry(_error_code, attempt_count) when attempt_count < @attempt_count_max, do: :retry
  defp retry(error_code, attempt_count), do: dead_letter(error_code, attempt_count, true)

  defp dead_letter(error_code, attempt_count, retries_exhausted) do
    {:dead_letter,
     %{
       error_code: error_code,
       error_message: Map.fetch!(@error_messages, error_code),
       attempt_count: attempt_count,
       retries_exhausted: retries_exhausted
     }}
  end
end
