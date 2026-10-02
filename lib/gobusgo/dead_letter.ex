defmodule Gobusgo.DeadLetter do
  @topic_suffix ".dead-letter"
  @exhausted_retry_condition "MaximumRetryAttempts"

  @moduledoc """
  The dead-letter record of a consumed record that its consumer gave up on.
  Everything here is pure.

  The record goes to the consumed topic's name followed by `#{@topic_suffix}`
  and keeps the key and the value exactly as consumed, so a value that is not
  an event is dead-lettered like any other. The failure is described in
  headers, each a UTF-8 string, placed after the consumed record's own:

    * `ERROR_CODE` — a short upper-case code.
    * `ERROR_MESSAGE` — one sentence, with no payload contents.
    * `RETRY_ATTEMPTS` — how many attempts were made.
    * `EXHAUSTED_RETRY_CONDITION` — `#{@exhausted_retry_condition}` when the
      retries ran out; absent for a failure sent without retrying.
    * `ORIGINAL_TOPIC`, `ORIGINAL_PARTITION`, `ORIGINAL_OFFSET` — where the
      record was consumed from.
    * `CONSUMER_GROUP` — the consumer group that gave up.
    * `FIRST_ATTEMPT_TIME`, `LAST_ATTEMPT_TIME` — UTC extended ISO 8601.

  A consumed header with one of these names is dropped, so a record
  dead-lettered twice describes its latest failure only.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Publisher

  @type consumed :: %{
          topic: String.t(),
          partition: non_neg_integer(),
          offset: non_neg_integer(),
          key: binary(),
          value: binary(),
          headers: [Publisher.header()]
        }

  @type failure :: %{
          error_code: String.t(),
          error_message: String.t(),
          attempt_count: pos_integer(),
          retries_exhausted: boolean()
        }

  @type request :: %{
          consumed: consumed(),
          consumer_group: String.t(),
          failure: failure(),
          first_attempt_at: DateTime.t(),
          last_attempt_at: DateTime.t()
        }

  # The first four names are EventBridge's dead-letter message attributes.
  # https://docs.aws.amazon.com/eventbridge/latest/userguide/eb-rule-dlq.html — checked 2026-10-02
  @header_names [
    "ERROR_CODE",
    "ERROR_MESSAGE",
    "RETRY_ATTEMPTS",
    "EXHAUSTED_RETRY_CONDITION",
    "ORIGINAL_TOPIC",
    "ORIGINAL_PARTITION",
    "ORIGINAL_OFFSET",
    "CONSUMER_GROUP",
    "FIRST_ATTEMPT_TIME",
    "LAST_ATTEMPT_TIME"
  ]

  @utc_time_zone "Etc/UTC"

  @doc "The dead-letter topic of `topic`."
  @spec topic(String.t()) :: String.t()
  def topic(topic) when is_binary(topic), do: topic <> @topic_suffix

  @doc """
  Returns the record that dead-letters `request.consumed`. Raises
  `Gobusgo.Assert.AssertionError` for a count or position below its minimum
  and for a time outside UTC.
  """
  @spec record(request()) :: Publisher.topic_record()
  def record(%{consumed: consumed, consumer_group: consumer_group, failure: failure} = request) do
    %{topic: topic, partition: partition, offset: offset, headers: headers} = consumed
    %{attempt_count: attempt_count, retries_exhausted: retries_exhausted} = failure
    Assert.condition(is_integer(partition), "partition must be an integer")
    Assert.condition(partition >= 0, "partition must be at least 0, got: #{partition}")
    Assert.condition(is_integer(offset), "offset must be an integer")
    Assert.condition(offset >= 0, "offset must be at least 0, got: #{offset}")
    Assert.condition(is_integer(attempt_count), "attempt_count must be an integer")

    Assert.condition(
      attempt_count >= 1,
      "attempt_count must be at least 1, got: #{attempt_count}"
    )

    Assert.condition(is_boolean(retries_exhausted), "retries_exhausted must be a boolean")

    failure_headers =
      [
        {"ERROR_CODE", failure.error_code},
        {"ERROR_MESSAGE", failure.error_message},
        {"RETRY_ATTEMPTS", Integer.to_string(attempt_count)}
      ] ++
        exhausted_headers(retries_exhausted) ++
        [
          {"ORIGINAL_TOPIC", topic},
          {"ORIGINAL_PARTITION", Integer.to_string(partition)},
          {"ORIGINAL_OFFSET", Integer.to_string(offset)},
          {"CONSUMER_GROUP", consumer_group},
          {"FIRST_ATTEMPT_TIME", time_text(request.first_attempt_at)},
          {"LAST_ATTEMPT_TIME", time_text(request.last_attempt_at)}
        ]

    %{
      topic: topic(topic),
      key: consumed.key,
      value: consumed.value,
      headers:
        Enum.reject(headers, fn {name, _text} -> name in @header_names end) ++ failure_headers
    }
  end

  defp exhausted_headers(true), do: [{"EXHAUSTED_RETRY_CONDITION", @exhausted_retry_condition}]
  defp exhausted_headers(false), do: []

  defp time_text(%DateTime{time_zone: time_zone} = time) do
    Assert.condition(time_zone == @utc_time_zone, "time must be in UTC, got: #{time_zone}")
    DateTime.to_iso8601(time, :extended)
  end
end
