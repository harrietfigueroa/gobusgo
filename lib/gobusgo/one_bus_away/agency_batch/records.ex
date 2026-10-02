defmodule Gobusgo.OneBusAway.AgencyBatch.Records do
  alias Gobusgo.CloudEvent

  @topic "oba.agencies-with-coverage.state"
  @source "/gobusgo/processor/oba/agencies-with-coverage"
  @agency_key_prefix "agency/"
  @manifest_key "manifest"
  @agency_type CloudEvent.type(%{name: "agency.processed", version: 1})
  @manifest_type CloudEvent.type(%{name: "agency.fetch.completed", version: 1})

  @moduledoc """
  The published form of one agency discovery fetch: one record per agency
  and one manifest record that completes the fetch. Everything here is pure,
  so the records are a function of the stored response alone and a repeated
  build yields the same bytes.

  Every record goes to the topic `#{@topic}` and holds one
  `Gobusgo.CloudEvent` whose `source` is `#{@source}` and whose `time` is
  the fetch time.

  ## Agency record

  One per agency, in identifier order.

    * Key: `#{@agency_key_prefix}<agency id>`.
    * `type`: `#{@agency_type}`.
    * `id`: `<requestId>/#{@agency_key_prefix}<agency id>`.
    * `subject`: the agency identifier.
    * `data.agency`: `id`, `name`, `url`, `timezone`, and `coverage` with
      `lat`, `lon`, `latSpan`, and `lonSpan`.
    * `data.fetchedAt`: the fetch time in UTC extended ISO 8601.
    * `data.requestId`: the request identifier of the fetch.

  ## Manifest record

  One per fetch.

    * Key: `#{@manifest_key}`. The prefix of every agency key keeps an agency
      identifier from ever equaling it.
    * `type`: `#{@manifest_type}`.
    * `id`: `<requestId>/#{@manifest_key}`.
    * `subject`: the destination of the stored response.
    * `data.agencyIds`: the identifier of every agency in the fetch, sorted.
    * `data.dataSha256`: the data hash of the stored response.
    * `data.destination`: the destination of the stored response.
    * `data.fetchedAt` and `data.requestId`: as in an agency record.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId

  @type t :: %{agencies: [Publisher.topic_record()], manifest: Publisher.topic_record()}

  @doc """
  Returns the records that publish `parsed`, a stored response as
  `Gobusgo.OneBusAway.RawAgencyResponse.parse/1` returns it. Raises
  `Gobusgo.Assert.AssertionError` when the request identifier is not a UUID
  version 7 or an agency identifier repeats.
  """
  @spec build(RawAgencyResponse.parsed()) :: t()
  def build(%{request_id: request_id, fetched_at: %DateTime{} = fetched_at} = parsed) do
    %{destination: destination, data_sha256: data_sha256, agencies: agencies} = parsed
    Assert.condition(RequestId.valid?(request_id), "request identifier must be a UUID version 7")

    agencies = Enum.sort_by(agencies, & &1.id)
    agency_ids = Enum.map(agencies, & &1.id)
    Assert.condition(agency_ids == Enum.dedup(agency_ids), "agency identifiers must be unique")

    fetch = %{
      "fetchedAt" => DateTime.to_iso8601(fetched_at, :extended),
      "requestId" => request_id
    }

    manifest_data =
      Map.merge(fetch, %{
        "agencyIds" => agency_ids,
        "dataSha256" => data_sha256,
        "destination" => destination
      })

    context = %{request_id: request_id, fetched_at: fetched_at, fetch: fetch}

    %{
      agencies: Enum.map(agencies, &agency_record(&1, context)),
      manifest:
        record(context, %{
          key: @manifest_key,
          type: @manifest_type,
          subject: destination,
          data: manifest_data
        })
    }
  end

  defp agency_record(%{id: id, coverage: coverage} = agency, %{fetch: fetch} = context) do
    data =
      Map.put(fetch, "agency", %{
        "id" => id,
        "name" => agency.name,
        "url" => agency.url,
        "timezone" => agency.timezone,
        "coverage" => %{
          "lat" => coverage.lat,
          "lon" => coverage.lon,
          "latSpan" => coverage.lat_span,
          "lonSpan" => coverage.lon_span
        }
      })

    record(context, %{key: @agency_key_prefix <> id, type: @agency_type, subject: id, data: data})
  end

  defp record(%{request_id: request_id, fetched_at: fetched_at}, %{key: key} = event) do
    CloudEvent.record(@topic, %{
      id: request_id <> "/" <> key,
      source: @source,
      type: event.type,
      time: fetched_at,
      subject: event.subject,
      partition_key: key,
      data: event.data
    })
  end
end
