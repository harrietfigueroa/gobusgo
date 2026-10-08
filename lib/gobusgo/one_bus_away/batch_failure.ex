defmodule Gobusgo.OneBusAway.BatchFailure do
  @moduledoc """
  The failure of processing one stored response, as every processor returns
  it: the stage that failed, its reason, its error code, and
  whether a repeated call fails the same way. Everything here is pure.

    * A read failure has the error code `READ_FAILURE`. It is `:permanent`
      for `:not_found`, `:content_too_large`, `:content_corrupt`, and
      `{:invalid_destination, reason}`, and `:transient` for
      `:permission_denied` and `:io_failure`.
    * A parse failure is `:permanent`, with the error code `INVALID_JSON`,
      `SCHEMA_MISMATCH`, `HASH_MISMATCH`, or `DESTINATION_MISMATCH`.
    * A publish failure has the error code `WRITE_FAILURE`. It is
      `:permanent` for `:record_too_large` and `:transient` for `:timeout`,
      `:unavailable`, and `:unknown_topic`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.RawResponse
  alias Gobusgo.Publisher
  alias Gobusgo.Reader

  @type t :: %{
          class: :permanent | :transient,
          error_code: String.t(),
          stage: atom(),
          reason: Reader.error_reason() | RawResponse.parse_error() | Publisher.error_reason()
        }

  @read_error_code "READ_FAILURE"
  @publish_error_code "WRITE_FAILURE"
  @parse_error_codes %{
    invalid_json: "INVALID_JSON",
    schema_mismatch: "SCHEMA_MISMATCH",
    hash_mismatch: "HASH_MISMATCH",
    destination_mismatch: "DESTINATION_MISMATCH"
  }

  @doc "The failure of reading the stored response, at the stage `:read`."
  @spec read(Reader.error_reason()) :: t()
  def read(reason) do
    class =
      case reason do
        :not_found -> :permanent
        :content_too_large -> :permanent
        :content_corrupt -> :permanent
        {:invalid_destination, _rule} -> :permanent
        :permission_denied -> :transient
        :io_failure -> :transient
        other -> Assert.unreachable(other)
      end

    %{class: class, error_code: @read_error_code, stage: :read, reason: reason}
  end

  @doc "The failure of parsing the stored response, at the stage `:parse`."
  @spec parse(RawResponse.parse_error()) :: t()
  def parse(reason) do
    %{
      class: :permanent,
      error_code: Map.fetch!(@parse_error_codes, reason),
      stage: :parse,
      reason: reason
    }
  end

  @doc "The failure of a publisher call at `stage`."
  @spec publish(atom(), Publisher.error_reason()) :: t()
  def publish(stage, reason) when is_atom(stage) do
    class =
      case reason do
        :record_too_large -> :permanent
        :timeout -> :transient
        :unavailable -> :transient
        :unknown_topic -> :transient
        other -> Assert.unreachable(other)
      end

    %{class: class, error_code: @publish_error_code, stage: stage, reason: reason}
  end
end
