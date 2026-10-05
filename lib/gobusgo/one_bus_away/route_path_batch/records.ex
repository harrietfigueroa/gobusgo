defmodule Gobusgo.OneBusAway.RoutePathBatch.Records do
  alias Gobusgo.CloudEvent

  @topic "oba.routes.state"
  @source "/gobusgo/processor/oba/stops-for-route"
  @key_prefix "stops-for-route/"
  @type_name CloudEvent.type(%{name: "route.path.processed", version: 1})

  @moduledoc """
  The published form of one fetch of a route's paths: one record that holds
  the lines of the route and of each of its stop groups. Everything here is
  pure, so the record is a function of the stored response alone and a
  repeated build yields the same bytes.

  The record goes to the topic `#{@topic}`, which the route datasets share,
  and holds one `Gobusgo.CloudEvent` whose `source` is `#{@source}` and whose
  `time` is the fetch time.

    * Key: `#{@key_prefix}<route id>`, so a route's newest record replaces
      its earlier ones.
    * `type`: `#{@type_name}`.
    * `id`: `<requestId>/#{@key_prefix}<route id>`.
    * `subject`: the route identifier.
    * `data.routeId`: the route.
    * `data.polylines`: the lines of the whole route, each with `points` in
      the encoded polyline format, `pointCount`, and `levels`, which is
      `null` when the source did not supply it.
    * `data.stopGroupings`: each with `type`, `ordered`, and `stopGroups`,
      and each group with `id`, `name`, `names`, `nameType`, `stopIds` in
      order, and its own `polylines`. `name` is `null` when the source did
      not supply it.
    * `data.dataSha256`: the data hash of the stored response.
    * `data.destination`: the destination of the stored response.
    * `data.fetchedAt`: the fetch time in UTC extended ISO 8601.
    * `data.requestId`: the request identifier of the fetch.

  The stops the stored response references are not in this record.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.RawRoutePathResponse
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId
  alias Gobusgo.Schema

  @typedoc """
  What one record holds. `id` is the route identifier, and `polylines` and
  `stop_groupings` are the JSON values of `data`, limited to the fields this
  module documents.
  """
  @type decoded :: %{
          id: String.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          destination: String.t(),
          polylines: [%{String.t() => term()}],
          stop_groupings: [%{String.t() => term()}]
        }

  @typedoc """
    * `:invalid_json` — the value is not JSON.
    * `:schema_mismatch` — the value is not a record `build/1` produces.
    * `:unsupported_type` — the value is an event of another `type`.
  """
  @type decode_error :: :invalid_json | :schema_mismatch | :unsupported_type

  @polyline_fields ["points", "pointCount", "levels"]
  @stop_group_fields ["id", "name", "names", "nameType", "stopIds", "polylines"]
  @stop_grouping_fields ["type", "ordered", "stopGroups"]

  @polyline_schema {:map,
                    %{
                      "points" => :string,
                      "pointCount" => :integer,
                      "levels" => {:nullable, :string}
                    }}

  @data_schema {:map,
                %{
                  "routeId" => :string,
                  "polylines" => {:list, @polyline_schema},
                  "stopGroupings" =>
                    {:list,
                     {:map,
                      %{
                        "type" => :string,
                        "ordered" => :boolean,
                        "stopGroups" =>
                          {:list,
                           {:map,
                            %{
                              "id" => :string,
                              "name" => {:nullable, :string},
                              "names" => {:list, :string},
                              "nameType" => :string,
                              "stopIds" => {:list, :string},
                              "polylines" => {:list, @polyline_schema}
                            }}}
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
  `Gobusgo.OneBusAway.RawRoutePathResponse.parse/1` returns it. Raises
  `Gobusgo.Assert.AssertionError` when the request identifier is not a UUID
  version 7 or the route identifier is empty.
  """
  @spec build(RawRoutePathResponse.parsed()) :: Publisher.topic_record()
  def build(%{request_id: request_id, fetched_at: %DateTime{} = fetched_at} = parsed) do
    %{route_id: route_id, route_path: route_path} = parsed
    Assert.condition(RequestId.valid?(request_id), "request identifier must be a UUID version 7")
    Assert.condition(is_binary(route_id), "route identifier must be a string")
    Assert.condition(route_id != "", "route identifier must be non-empty")
    Assert.condition(route_path.route_id == route_id, "the path must be the route's own")
    key = @key_prefix <> route_id

    CloudEvent.record(@topic, %{
      id: request_id <> "/" <> key,
      source: @source,
      type: @type_name,
      time: fetched_at,
      subject: route_id,
      partition_key: key,
      data: %{
        "routeId" => route_id,
        "polylines" => Enum.map(route_path.polylines, &polyline_data/1),
        "stopGroupings" => Enum.map(route_path.stop_groupings, &stop_grouping_data/1),
        "dataSha256" => parsed.data_sha256,
        "destination" => parsed.destination,
        "fetchedAt" => DateTime.to_iso8601(fetched_at, :extended),
        "requestId" => request_id
      }
    })
  end

  defp polyline_data(polyline) do
    %{
      "points" => polyline.points,
      "pointCount" => polyline.point_count,
      "levels" => polyline.levels
    }
  end

  defp stop_grouping_data(stop_grouping) do
    %{
      "type" => stop_grouping.type,
      "ordered" => stop_grouping.ordered,
      "stopGroups" => Enum.map(stop_grouping.stop_groups, &stop_group_data/1)
    }
  end

  defp stop_group_data(stop_group) do
    %{
      "id" => stop_group.id,
      "name" => stop_group.name,
      "names" => stop_group.names,
      "nameType" => stop_group.name_type,
      "stopIds" => stop_group.stop_ids,
      "polylines" => Enum.map(stop_group.polylines, &polyline_data/1)
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
         {:ok, fetched_at, 0} <- DateTime.from_iso8601(data["fetchedAt"]) do
      {:ok,
       %{
         id: route_id,
         request_id: request_id,
         fetched_at: fetched_at,
         data_sha256: data["dataSha256"],
         destination: data["destination"],
         polylines: Enum.map(data["polylines"], &Map.take(&1, @polyline_fields)),
         stop_groupings: Enum.map(data["stopGroupings"], &stop_grouping/1)
       }}
    else
      _mismatch -> {:error, :schema_mismatch}
    end
  end

  defp stop_grouping(%{"stopGroups" => stop_groups} = stop_grouping) do
    stop_grouping
    |> Map.take(@stop_grouping_fields)
    |> Map.put("stopGroups", Enum.map(stop_groups, &stop_group/1))
  end

  defp stop_group(%{"polylines" => polylines} = stop_group) do
    stop_group
    |> Map.take(@stop_group_fields)
    |> Map.put("polylines", Enum.map(polylines, &Map.take(&1, @polyline_fields)))
  end
end
