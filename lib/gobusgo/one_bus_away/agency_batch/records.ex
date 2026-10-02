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
  alias Gobusgo.Schema

  @type t :: %{agencies: [Publisher.topic_record()], manifest: Publisher.topic_record()}

  @type fetch :: %{request_id: RequestId.t(), fetched_at: DateTime.t()}

  @typedoc """
  What one record holds. An agency is the JSON object of `data.agency`,
  limited to the fields this module documents.
  """
  @type decoded ::
          {:agency,
           %{
             request_id: RequestId.t(),
             fetched_at: DateTime.t(),
             agency: %{String.t() => term()}
           }}
          | {:manifest,
             %{
               request_id: RequestId.t(),
               fetched_at: DateTime.t(),
               agency_ids: [String.t()],
               data_sha256: String.t(),
               destination: String.t()
             }}

  @typedoc """
    * `:invalid_json` — the value is not JSON.
    * `:schema_mismatch` — the value is not a record `build/1` produces.
    * `:unsupported_type` — the value is an event of another `type`.
  """
  @type decode_error :: :invalid_json | :schema_mismatch | :unsupported_type

  @coverage_fields ["lat", "lon", "latSpan", "lonSpan"]
  @agency_fields ["id", "name", "url", "timezone", "coverage"]

  @agency_data_schema {:map,
                       %{
                         "agency" =>
                           {:map,
                            %{
                              "id" => :string,
                              "name" => :string,
                              "url" => :string,
                              "timezone" => :string,
                              "coverage" =>
                                {:map,
                                 %{
                                   "lat" => :number,
                                   "lon" => :number,
                                   "latSpan" => :number,
                                   "lonSpan" => :number
                                 }}
                            }},
                         "fetchedAt" => :string,
                         "requestId" => :string
                       }}

  @manifest_data_schema {:map,
                         %{
                           "agencyIds" => {:list, :string},
                           "dataSha256" => :string,
                           "destination" => :string,
                           "fetchedAt" => :string,
                           "requestId" => :string
                         }}

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

  @doc """
  Returns what `value`, the value of a record `build/1` produces, holds. The
  first rule the value breaks returns as a value.
  """
  @spec decode(binary()) :: {:ok, decoded()} | {:error, decode_error()}
  def decode(value) when is_binary(value) do
    with {:ok, %{type: type, data: data}} <- CloudEvent.decode(value) do
      case type do
        @agency_type -> decode_agency(data)
        @manifest_type -> decode_manifest(data)
        _other -> {:error, :unsupported_type}
      end
    end
  end

  defp decode_agency(data) do
    with nil <- Schema.mismatch(data, @agency_data_schema),
         {:ok, fetch} <- decode_fetch(data),
         %{"id" => id, "coverage" => coverage} = agency = data["agency"],
         true <- id != "" do
      agency =
        agency
        |> Map.take(@agency_fields)
        |> Map.put("coverage", Map.take(coverage, @coverage_fields))

      {:ok, {:agency, Map.put(fetch, :agency, agency)}}
    else
      _mismatch -> {:error, :schema_mismatch}
    end
  end

  defp decode_manifest(data) do
    with nil <- Schema.mismatch(data, @manifest_data_schema),
         {:ok, fetch} <- decode_fetch(data) do
      {:ok,
       {:manifest,
        Map.merge(fetch, %{
          agency_ids: data["agencyIds"],
          data_sha256: data["dataSha256"],
          destination: data["destination"]
        })}}
    else
      _mismatch -> {:error, :schema_mismatch}
    end
  end

  defp decode_fetch(%{"fetchedAt" => fetched_at_text, "requestId" => request_id}) do
    with true <- RequestId.valid?(request_id),
         {:ok, fetched_at, 0} <- DateTime.from_iso8601(fetched_at_text) do
      {:ok, %{request_id: request_id, fetched_at: fetched_at}}
    else
      _mismatch -> :error
    end
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
