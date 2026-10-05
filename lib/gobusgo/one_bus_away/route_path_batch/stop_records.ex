defmodule Gobusgo.OneBusAway.RoutePathBatch.StopRecords do
  alias Gobusgo.CloudEvent

  @topic "oba.stops.state"
  @source "/gobusgo/processor/oba/stops-for-route"
  @key_prefix "stops-for-route/"
  @id_infix "/route-stops/"
  @type_name CloudEvent.type(%{name: "route.stops.processed", version: 1})

  @moduledoc """
  The published form of the stops in one fetch of a route's stops and
  paths: one record that holds every stop the route lists and the parent
  stops those stops name. Everything here is pure, so the record is a
  function of the stored response alone and a repeated build yields the same
  bytes.

  The record goes to the topic `#{@topic}` and holds one `Gobusgo.CloudEvent`
  whose `source` is `#{@source}` and whose `time` is the fetch time.

    * Key: `#{@key_prefix}<route id>`, so a route's newest record replaces
      its earlier ones.
    * `type`: `#{@type_name}`.
    * `id`: `<requestId>#{@id_infix}<route id>`.
    * `subject`: the route identifier.
    * `data.routeId`: the route.
    * `data.stops`: the stops the route lists, in the route's order, each
      with `id`, `name`, `lat`, `lon`, `code`, `direction`, `locationType`,
      `parent`, `wheelchairBoarding`, and `routeIds`. `code`, `direction`,
      and `parent` are `null` when the source did not supply them.
    * `data.parentStops`: the stops outside `data.stops` that those stops
      name as `parent`, in identifier order, with the same fields.
    * `data.dataSha256`: the data hash of the stored response.
    * `data.destination`: the destination of the stored response.
    * `data.fetchedAt`: the fetch time in UTC extended ISO 8601.
    * `data.requestId`: the request identifier of the fetch.

  A stop identifier appears once in `data.stops` and `data.parentStops`
  together.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.RawRoutePathResponse
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId
  alias Gobusgo.Schema

  @typedoc "A stop as a record holds it: the JSON value, limited to the fields this module documents."
  @type stop :: %{String.t() => term()}

  @typedoc "What one record holds. `id` is the route identifier."
  @type decoded :: %{
          id: String.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          destination: String.t(),
          stops: [stop()],
          parent_stops: [stop()]
        }

  @typedoc """
    * `:invalid_json` — the value is not JSON.
    * `:schema_mismatch` — the value is not a record `build/1` produces.
    * `:unsupported_type` — the value is an event of another `type`.
  """
  @type decode_error :: :invalid_json | :schema_mismatch | :unsupported_type

  @stop_schema {:map,
                %{
                  "id" => :string,
                  "name" => :string,
                  "lat" => :number,
                  "lon" => :number,
                  "code" => {:nullable, :string},
                  "direction" => {:nullable, :string},
                  "locationType" => :integer,
                  "parent" => {:nullable, :string},
                  "wheelchairBoarding" => :string,
                  "routeIds" => {:list, :string}
                }}

  {:map, stop_fields} = @stop_schema
  @stop_fields Map.keys(stop_fields)

  @data_schema {:map,
                %{
                  "routeId" => :string,
                  "stops" => {:list, @stop_schema},
                  "parentStops" => {:list, @stop_schema},
                  "dataSha256" => :string,
                  "destination" => :string,
                  "fetchedAt" => :string,
                  "requestId" => :string
                }}

  @doc "The topic the record goes to."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Returns the record that publishes the stops of `parsed`, a stored response
  as `Gobusgo.OneBusAway.RawRoutePathResponse.parse/1` returns it. Raises
  `Gobusgo.Assert.AssertionError` when the request identifier is not a UUID
  version 7 or the route identifier is empty.
  """
  @spec build(RawRoutePathResponse.parsed()) :: Publisher.topic_record()
  def build(%{request_id: request_id, fetched_at: %DateTime{} = fetched_at} = parsed) do
    %{route_id: route_id, route_path: route_path} = parsed
    Assert.condition(RequestId.valid?(request_id), "request identifier must be a UUID version 7")
    Assert.condition(is_binary(route_id), "route identifier must be a string")
    Assert.condition(route_id != "", "route identifier must be non-empty")
    Assert.condition(route_path.route_id == route_id, "the stops must be the route's own")

    CloudEvent.record(@topic, %{
      id: request_id <> @id_infix <> route_id,
      source: @source,
      type: @type_name,
      time: fetched_at,
      subject: route_id,
      partition_key: @key_prefix <> route_id,
      data: %{
        "routeId" => route_id,
        "stops" => Enum.map(route_path.stops, &stop_data/1),
        "parentStops" => Enum.map(route_path.parent_stops, &stop_data/1),
        "dataSha256" => parsed.data_sha256,
        "destination" => parsed.destination,
        "fetchedAt" => DateTime.to_iso8601(fetched_at, :extended),
        "requestId" => request_id
      }
    })
  end

  defp stop_data(stop) do
    %{
      "id" => stop.id,
      "name" => stop.name,
      "lat" => stop.lat,
      "lon" => stop.lon,
      "code" => stop.code,
      "direction" => stop.direction,
      "locationType" => stop.location_type,
      "parent" => stop.parent,
      "wheelchairBoarding" => stop.wheelchair_boarding,
      "routeIds" => stop.route_ids
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
         %{"routeId" => route_id, "requestId" => request_id} = data,
         true <- route_id != "",
         true <- RequestId.valid?(request_id),
         {:ok, fetched_at, 0} <- DateTime.from_iso8601(data["fetchedAt"]),
         true <- distinct_ids?(data["stops"] ++ data["parentStops"]) do
      {:ok,
       %{
         id: route_id,
         request_id: request_id,
         fetched_at: fetched_at,
         data_sha256: data["dataSha256"],
         destination: data["destination"],
         stops: Enum.map(data["stops"], &Map.take(&1, @stop_fields)),
         parent_stops: Enum.map(data["parentStops"], &Map.take(&1, @stop_fields))
       }}
    else
      _mismatch -> {:error, :schema_mismatch}
    end
  end

  # The rules the schema cannot express: an identifier is non-empty and
  # names one stop of the record.
  defp distinct_ids?(stops) do
    ids = Enum.map(stops, & &1["id"])

    if Enum.all?(ids, &(&1 != "")) do
      length(Enum.uniq(ids)) == length(ids)
    else
      false
    end
  end
end
