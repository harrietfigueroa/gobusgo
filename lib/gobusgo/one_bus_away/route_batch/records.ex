defmodule Gobusgo.OneBusAway.RouteBatch.Records do
  alias Gobusgo.CloudEvent

  @topic "oba.routes.state"
  @source "/gobusgo/processor/oba/routes-for-agency"
  @key_prefix "routes-for-agency/"
  @type_name CloudEvent.type(%{name: "agency.routes.processed", version: 1})

  @moduledoc """
  The published form of one fetch of an agency's routes: one record that
  holds every route of the agency. Everything here is pure, so the record is
  a function of the stored response alone and a repeated build yields the
  same bytes.

  The record goes to the topic `#{@topic}`, which the route datasets share,
  and holds one `Gobusgo.CloudEvent` whose `source` is `#{@source}` and whose
  `time` is the fetch time.

    * Key: `#{@key_prefix}<agency id>`, so an agency's newest record replaces
      its earlier ones and a route the agency drops leaves with them.
    * `type`: `#{@type_name}`.
    * `id`: `<requestId>/#{@key_prefix}<agency id>`.
    * `subject`: the agency identifier.
    * `data.agencyId`: the agency.
    * `data.routes`: the routes in identifier order, each with `id`,
      `agencyId`, `shortName`, `longName`, `description`, `type`, `color`,
      `textColor`, and `url`. Every field but `id`, `agencyId`, and `type` is
      `null` when the source did not supply it.
    * `data.dataSha256`: the data hash of the stored response.
    * `data.destination`: the destination of the stored response.
    * `data.fetchedAt`: the fetch time in UTC extended ISO 8601.
    * `data.requestId`: the request identifier of the fetch.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.RawRouteResponse
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId
  alias Gobusgo.Schema

  @typedoc """
  What one record holds. `id` is the agency identifier, and a route is the
  JSON object of `data.routes`, limited to the fields this module documents.
  """
  @type decoded :: %{
          id: String.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          destination: String.t(),
          route_ids: [String.t()],
          routes: %{String.t() => %{String.t() => term()}}
        }

  @typedoc """
    * `:invalid_json` — the value is not JSON.
    * `:schema_mismatch` — the value is not a record `build/1` produces.
    * `:unsupported_type` — the value is an event of another `type`.
  """
  @type decode_error :: :invalid_json | :schema_mismatch | :unsupported_type

  @route_fields [
    "id",
    "agencyId",
    "shortName",
    "longName",
    "description",
    "type",
    "color",
    "textColor",
    "url"
  ]

  @data_schema {:map,
                %{
                  "agencyId" => :string,
                  "routes" =>
                    {:list,
                     {:map,
                      %{
                        "id" => :string,
                        "agencyId" => :string,
                        "shortName" => {:nullable, :string},
                        "longName" => {:nullable, :string},
                        "description" => {:nullable, :string},
                        "type" => :integer,
                        "color" => {:nullable, :string},
                        "textColor" => {:nullable, :string},
                        "url" => {:nullable, :string}
                      }}},
                  "dataSha256" => :string,
                  "destination" => :string,
                  "fetchedAt" => :string,
                  "requestId" => :string
                }}

  @doc "The topic the record goes to."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Returns the record that publishes `parsed`, a stored response as
  `Gobusgo.OneBusAway.RawRouteResponse.parse/1` returns it. Raises
  `Gobusgo.Assert.AssertionError` when the request identifier is not a UUID
  version 7, the agency identifier is empty, or a route identifier repeats.
  """
  @spec build(RawRouteResponse.parsed()) :: Publisher.topic_record()
  def build(%{request_id: request_id, fetched_at: %DateTime{} = fetched_at} = parsed) do
    %{agency_id: agency_id, routes: routes} = parsed
    Assert.condition(RequestId.valid?(request_id), "request identifier must be a UUID version 7")
    Assert.condition(is_binary(agency_id), "agency identifier must be a string")
    Assert.condition(agency_id != "", "agency identifier must be non-empty")

    routes = Enum.sort_by(routes, & &1.id)
    route_ids = Enum.map(routes, & &1.id)
    Assert.condition(route_ids == Enum.dedup(route_ids), "route identifiers must be unique")
    key = @key_prefix <> agency_id

    CloudEvent.record(@topic, %{
      id: request_id <> "/" <> key,
      source: @source,
      type: @type_name,
      time: fetched_at,
      subject: agency_id,
      partition_key: key,
      data: %{
        "agencyId" => agency_id,
        "routes" => Enum.map(routes, &route_data/1),
        "dataSha256" => parsed.data_sha256,
        "destination" => parsed.destination,
        "fetchedAt" => DateTime.to_iso8601(fetched_at, :extended),
        "requestId" => request_id
      }
    })
  end

  defp route_data(route) do
    %{
      "id" => route.id,
      "agencyId" => route.agency_id,
      "shortName" => route.short_name,
      "longName" => route.long_name,
      "description" => route.description,
      "type" => route.type,
      "color" => route.color,
      "textColor" => route.text_color,
      "url" => route.url
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
        @type_name -> decode_data(data)
        _other -> {:error, :unsupported_type}
      end
    end
  end

  defp decode_data(data) do
    with nil <- Schema.mismatch(data, @data_schema),
         %{"agencyId" => agency_id, "requestId" => request_id, "routes" => routes} = data,
         true <- agency_id != "",
         true <- RequestId.valid?(request_id),
         {:ok, fetched_at, 0} <- DateTime.from_iso8601(data["fetchedAt"]),
         route_ids = Enum.map(routes, & &1["id"]),
         true <- route_ids == Enum.uniq(route_ids) do
      {:ok,
       %{
         id: agency_id,
         request_id: request_id,
         fetched_at: fetched_at,
         data_sha256: data["dataSha256"],
         destination: data["destination"],
         route_ids: route_ids,
         routes: Map.new(routes, &{&1["id"], Map.take(&1, @route_fields)})
       }}
    else
      _mismatch -> {:error, :schema_mismatch}
    end
  end
end
