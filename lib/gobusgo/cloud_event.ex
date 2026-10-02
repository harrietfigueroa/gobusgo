defmodule Gobusgo.CloudEvent do
  @spec_version "1.0"
  @type_prefix "gobusgo."

  @moduledoc """
  CloudEvents #{@spec_version} in structured mode: one JSON document that
  holds the attributes and the data of an event. Everything here is pure, so
  the encoded event is a function of the event alone.

  An event is a map of:

    * `:id` — identifies the event within its `:source`.
    * `:source` — the producer, as an absolute path such as
      `/gobusgo/recorder/oba/agencies-with-coverage`.
    * `:type` — what happened, built with `type/1`.
    * `:time` — when it happened, in UTC.
    * `:subject` — what the event is about.
    * `:partition_key` — the key that keeps related events in order.
    * `:data` — the payload, a map with string keys.

  The document is compact JSON with object keys sorted. `time` is extended
  ISO 8601, and `datacontenttype` is always `application/json`.

  ## Versioning

  The version is the suffix of `type`, such as `#{@type_prefix}response.stored.v1`.
  It rises when a field of `data` is removed or renamed, or changes type or
  meaning; an added field leaves it as is.
  """

  alias Gobusgo.Assert
  alias Gobusgo.CanonicalJson
  alias Gobusgo.Publisher

  @type t :: %{
          id: String.t(),
          source: String.t(),
          type: String.t(),
          time: DateTime.t(),
          subject: String.t(),
          partition_key: String.t(),
          data: %{String.t() => term()}
        }

  # The attribute rules encode/1 asserts: `id` and `subject` are non-empty
  # strings and `source` is a URI-reference.
  # https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/spec.md — checked 2026-10-02
  @data_content_type "application/json"
  @source_prefix "/"
  @utc_time_zone "Etc/UTC"

  # A structured-mode record names the event format's media type in its
  # `content-type` header and takes the `partitionkey` attribute as its key.
  # https://github.com/cloudevents/spec/blob/v1.0.2/cloudevents/bindings/kafka-protocol-binding.md — checked 2026-10-02
  @content_type_header "content-type"
  @content_type "application/cloudevents+json"

  @doc """
  Returns the `type` for `name`, dot-separated words such as
  `response.stored`, at `version`, a positive integer.
  """
  @spec type(%{name: String.t(), version: pos_integer()}) :: String.t()
  def type(%{name: name, version: version}) do
    assert_text(name, "name")
    Assert.condition(is_integer(version), "version must be an integer, got: #{inspect(version)}")
    Assert.condition(version >= 1, "version must be at least 1, got: #{version}")

    @type_prefix <> name <> ".v" <> Integer.to_string(version)
  end

  @doc """
  Returns `event` as one structured-mode JSON document. Raises
  `Gobusgo.Assert.AssertionError` when the event breaks the rules in the
  module documentation.
  """
  @spec encode(t()) :: binary()
  def encode(%{source: source, type: type, time: %DateTime{} = time, data: data} = event) do
    %{id: id, subject: subject, partition_key: partition_key} = event
    assert_text(id, "id")
    assert_text(subject, "subject")
    assert_text(partition_key, "partition_key")
    assert_text(source, "source")
    assert_text(type, "type")

    Assert.condition(
      String.starts_with?(source, @source_prefix),
      "source must start with #{@source_prefix}, got: #{source}"
    )

    Assert.condition(
      String.starts_with?(type, @type_prefix),
      "type must start with #{@type_prefix}, got: #{type}"
    )

    Assert.condition(
      time.time_zone == @utc_time_zone,
      "time must be in UTC, got: #{time.time_zone}"
    )

    Assert.condition(is_map(data), "data must be a map")

    CanonicalJson.encode(%{
      "specversion" => @spec_version,
      "id" => id,
      "source" => source,
      "type" => type,
      "time" => DateTime.to_iso8601(time, :extended),
      "subject" => subject,
      "datacontenttype" => @data_content_type,
      "partitionkey" => partition_key,
      "data" => data
    })
  end

  @doc """
  Returns the record that publishes `event` to `topic`: the encoded event,
  keyed by the event's partition key.
  """
  @spec record(String.t(), t()) :: Publisher.topic_record()
  def record(topic, %{partition_key: partition_key} = event) when is_binary(topic) do
    %{
      topic: topic,
      key: partition_key,
      value: encode(event),
      headers: [{@content_type_header, @content_type}]
    }
  end

  defp assert_text(value, name) do
    Assert.condition(is_binary(value), "#{name} must be a string, got: #{inspect(value)}")
    Assert.condition(value != "", "#{name} must be non-empty")
  end
end
