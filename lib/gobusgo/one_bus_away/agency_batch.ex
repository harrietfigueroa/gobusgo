defmodule Gobusgo.OneBusAway.AgencyBatch do
  @moduledoc """
  Processes one stored agency discovery response: the response at a
  destination, read through `Gobusgo.Reader` and published through
  `Gobusgo.Publisher` as one record per agency followed by one manifest
  record. This module orchestrates and logs; the stored form of the input
  lives in `Gobusgo.OneBusAway.RawAgencyResponse` and the published form in
  `Gobusgo.OneBusAway.AgencyBatch.Records`.

  `process/2` runs in the calling process and starts none. It names no
  backend; application configuration selects them. It keeps nothing between
  calls, so every valid response is published, changed or not, and a
  repeated call publishes the same records again.

  ## Usage

      destination =
        "raw/oba/agencies-with-coverage/dt=2026-10-02/" <>
          "20261002T031500Z_0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10_3f2a9c1b7d4e.json.gz"

      case Gobusgo.OneBusAway.AgencyBatch.process(destination, []) do
        {:ok, %{agency_count: agency_count}} -> agency_count
        {:error, %{class: class, error_code: error_code}} -> {class, error_code}
      end

  ## Order

  The agency records are published first, in one call that returns once
  every one is acknowledged. The manifest record is published after that
  call returns `:ok`, so a manifest exists only for a fetch whose agency
  records are all stored. A response without agencies publishes the manifest
  alone.

  ## Results

  `{:ok, result}`, where `result` holds the `:destination`, the
  `:request_id` and `:fetched_at` of the fetch, and the `:agency_count`.

  `{:error, failure}`, where `failure` holds:

    * `:stage` — `:read`, `:parse`, `:publish_agencies`, or
      `:publish_manifest`. No manifest is published for a failure at any
      stage.
    * `:reason` — a `t:Gobusgo.Reader.error_reason/0` at `:read`, a
      `t:Gobusgo.OneBusAway.RawAgencyResponse.parse_error/0` at `:parse`, and
      a `t:Gobusgo.Publisher.error_reason/0` at the publish stages.
    * `:error_code` — `READ_FAILURE` at `:read`; `INVALID_JSON`,
      `SCHEMA_MISMATCH`, `HASH_MISMATCH`, or `DESTINATION_MISMATCH` at
      `:parse`; `WRITE_FAILURE` at the publish stages.
    * `:class` — `:permanent` when a repeated call fails the same way: every
      `:parse` failure, a read that returns `:not_found`,
      `:content_too_large`, `:content_corrupt`, or
      `{:invalid_destination, reason}`, and a
      publish that returns `:record_too_large`. `:transient` otherwise.

  A call that publishes logs once at `info`. A failure returns to the caller
  and is not logged here.

  ## Options

    * `:read_options`: options for `Gobusgo.Reader.read/2`.
    * `:publish_options`: options for `Gobusgo.Publisher.publish/2`.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.AgencyBatch.Records
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.Publisher
  alias Gobusgo.Reader
  alias Gobusgo.RequestId

  @type result :: %{
          destination: String.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          agency_count: non_neg_integer()
        }

  @type stage :: :read | :parse | :publish_agencies | :publish_manifest

  @type failure :: %{
          class: :permanent | :transient,
          error_code: String.t(),
          stage: stage(),
          reason:
            Reader.error_reason() | RawAgencyResponse.parse_error() | Publisher.error_reason()
        }

  @read_error_code "READ_FAILURE"
  @publish_error_code "WRITE_FAILURE"
  @parse_error_codes %{
    invalid_json: "INVALID_JSON",
    schema_mismatch: "SCHEMA_MISMATCH",
    hash_mismatch: "HASH_MISMATCH",
    destination_mismatch: "DESTINATION_MISMATCH"
  }

  @doc "Publishes the agencies and the manifest of the response stored at `destination`."
  @spec process(String.t(), Keyword.t()) :: {:ok, result()} | {:error, failure()}
  def process(destination, options) when is_binary(destination) and is_list(options) do
    options = Keyword.validate!(options, read_options: [], publish_options: [])
    publish_options = Keyword.fetch!(options, :publish_options)

    result =
      with {:ok, content} <- read(destination, Keyword.fetch!(options, :read_options)),
           {:ok, parsed} <- parse(destination, content),
           %{agencies: agencies, manifest: manifest} = Records.build(parsed),
           :ok <- publish(:publish_agencies, agencies, publish_options),
           :ok <- publish(:publish_manifest, [manifest], publish_options) do
        {:ok,
         %{
           destination: destination,
           request_id: parsed.request_id,
           fetched_at: parsed.fetched_at,
           agency_count: length(agencies)
         }}
      end

    with {:ok, published} <- result do
      Logger.info("Agency batch published",
        destination: destination,
        request_id: published.request_id,
        agency_count: published.agency_count
      )
    end

    result
  end

  defp read(destination, read_options) do
    case Reader.read(destination, read_options) do
      {:ok, content} ->
        {:ok, content}

      {:error, reason} ->
        {:error,
         %{class: read_class(reason), error_code: @read_error_code, stage: :read, reason: reason}}
    end
  end

  defp read_class(reason) do
    case reason do
      :not_found -> :permanent
      :content_too_large -> :permanent
      :content_corrupt -> :permanent
      {:invalid_destination, _rule} -> :permanent
      :permission_denied -> :transient
      :io_failure -> :transient
      other -> Assert.unreachable(other)
    end
  end

  defp parse(destination, content) do
    case RawAgencyResponse.parse(%{destination: destination, content: content}) do
      {:ok, parsed} ->
        {:ok, parsed}

      {:error, reason} ->
        {:error,
         %{
           class: :permanent,
           error_code: Map.fetch!(@parse_error_codes, reason),
           stage: :parse,
           reason: reason
         }}
    end
  end

  defp publish(:publish_agencies, [], _publish_options), do: :ok

  defp publish(stage, records, publish_options) do
    case Publisher.publish(records, publish_options) do
      :ok ->
        :ok

      {:error, reason} ->
        {:error,
         %{
           class: publish_class(reason),
           error_code: @publish_error_code,
           stage: stage,
           reason: reason
         }}
    end
  end

  defp publish_class(reason) do
    case reason do
      :record_too_large -> :permanent
      :timeout -> :transient
      :unavailable -> :transient
      :unknown_topic -> :transient
      other -> Assert.unreachable(other)
    end
  end
end
