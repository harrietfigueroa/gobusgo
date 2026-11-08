defmodule Gobusgo.OneBusAway.RouteScheduleBatch.Records do
  alias Gobusgo.CloudEvent

  @topic "oba.schedules.state"
  @source "/gobusgo/processor/oba/schedule-for-route"
  @key_prefix "schedule-for-route/"
  @type_name CloudEvent.type(%{name: "route.schedule.processed", version: 1})

  @moduledoc """
  The published form of one fetch of a route's schedule on one service date:
  one record that holds every trip of the route on that date. Everything
  here is pure, so the record is a function of the stored response alone and
  a repeated build yields the same bytes.

  The record goes to the topic `#{@topic}` and holds one `Gobusgo.CloudEvent`
  whose `source` is `#{@source}` and whose `time` is the fetch time.

    * Key: `#{@key_prefix}<route id>/<service date>`, so the newest record of
      a route and a date replaces its earlier ones.
    * `type`: `#{@type_name}`.
    * `id`: `<requestId>/#{@key_prefix}<route id>/<service date>`.
    * `subject`: the route identifier.
    * `data.routeId`: the route.
    * `data.serviceDate`: the service date the request asked for, as
      `YYYY-MM-DD`.
    * `data.scheduleDate`: the start of the service date the source
      answered for, in milliseconds since the Unix epoch.
    * `data.serviceIds`: the services running that date.
    * `data.stopIds`: every stop the trips serve, once, in the order the
      trips first serve them.
    * `data.trips`: each with `id`, `directionId`, `headsign`, `blockId`,
      `serviceId`, and `shapeId`, the last four `null` where the source
      sends none but `serviceId`, and its stop times as five lists of one
      entry per stop time: `stopIndexes` into `data.stopIds`, `arrivalS` and
      `departureS` in seconds from the start of the service day, and
      `arrivalEnabled` and `departureEnabled`.
    * `data.dataSha256`: the data hash of the stored response.
    * `data.destination`: the destination of the stored response.
    * `data.fetchedAt`: the fetch time in UTC extended ISO 8601.
    * `data.requestId`: the request identifier of the fetch.

  `decode/1` returns the schedule as `Gobusgo.OneBusAway.CompactSchedule`
  packs it, the form a view holds.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.CompactSchedule
  alias Gobusgo.OneBusAway.RawRouteScheduleResponse
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId
  alias Gobusgo.Schema

  @typedoc "What one record holds. `id` is the route identifier."
  @type decoded :: %{
          id: String.t(),
          service_date: Date.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          destination: String.t(),
          schedule: CompactSchedule.t()
        }

  @typedoc """
    * `:invalid_json` — the value is not JSON.
    * `:schema_mismatch` — the value is not a record `build/1` produces.
    * `:unsupported_type` — the value is an event of another `type`.
  """
  @type decode_error :: :invalid_json | :schema_mismatch | :unsupported_type

  @trip_schema {:map,
                %{
                  "id" => :string,
                  "directionId" => :string,
                  "headsign" => {:nullable, :string},
                  "blockId" => {:nullable, :string},
                  "serviceId" => :string,
                  "shapeId" => {:nullable, :string},
                  "stopIndexes" => {:list, :integer},
                  "arrivalS" => {:list, :integer},
                  "departureS" => {:list, :integer},
                  "arrivalEnabled" => {:list, :boolean},
                  "departureEnabled" => {:list, :boolean}
                }}

  @data_schema {:map,
                %{
                  "routeId" => :string,
                  "serviceDate" => :string,
                  "scheduleDate" => :integer,
                  "serviceIds" => {:list, :string},
                  "stopIds" => {:list, :string},
                  "trips" => {:list, @trip_schema},
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
  `Gobusgo.OneBusAway.RawRouteScheduleResponse.parse/1` returns it. Raises
  `Gobusgo.Assert.AssertionError` when the request identifier is not a UUID
  version 7 or the route identifier is empty.
  """
  @spec build(RawRouteScheduleResponse.parsed()) :: Publisher.topic_record()
  def build(%{request_id: request_id, fetched_at: %DateTime{} = fetched_at} = parsed) do
    %{route_id: route_id, service_date: %Date{} = service_date, schedule: schedule} = parsed
    Assert.condition(RequestId.valid?(request_id), "request identifier must be a UUID version 7")
    Assert.condition(is_binary(route_id), "route identifier must be a string")
    Assert.condition(route_id != "", "route identifier must be non-empty")
    Assert.condition(schedule.route_id == route_id, "the schedule must be the route's own")
    service_date_text = Date.to_iso8601(service_date)
    key = @key_prefix <> route_id <> "/" <> service_date_text
    listed = CompactSchedule.list(schedule)

    CloudEvent.record(@topic, %{
      id: request_id <> "/" <> key,
      source: @source,
      type: @type_name,
      time: fetched_at,
      subject: route_id,
      partition_key: key,
      data: %{
        "routeId" => route_id,
        "serviceDate" => service_date_text,
        "scheduleDate" => listed.schedule_date_ms,
        "serviceIds" => listed.service_ids,
        "stopIds" => listed.stop_ids,
        "trips" => Enum.map(listed.trips, &trip_data/1),
        "dataSha256" => parsed.data_sha256,
        "destination" => parsed.destination,
        "fetchedAt" => DateTime.to_iso8601(fetched_at, :extended),
        "requestId" => request_id
      }
    })
  end

  defp trip_data(trip) do
    %{
      "id" => trip.id,
      "directionId" => trip.direction_id,
      "headsign" => trip.headsign,
      "blockId" => trip.block_id,
      "serviceId" => trip.service_id,
      "shapeId" => trip.shape_id,
      "stopIndexes" => trip.stop_indexes,
      "arrivalS" => trip.arrival_s,
      "departureS" => trip.departure_s,
      "arrivalEnabled" => trip.arrival_enabled,
      "departureEnabled" => trip.departure_enabled
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
         {:ok, service_date} <- Date.from_iso8601(data["serviceDate"]),
         {:ok, fetched_at, 0} <- DateTime.from_iso8601(data["fetchedAt"]),
         {:ok, schedule} <- CompactSchedule.pack(listed(data)) do
      {:ok,
       %{
         id: route_id,
         service_date: service_date,
         request_id: request_id,
         fetched_at: fetched_at,
         data_sha256: data["dataSha256"],
         destination: data["destination"],
         schedule: schedule
       }}
    else
      _mismatch -> {:error, :schema_mismatch}
    end
  end

  defp listed(data) do
    %{
      route_id: data["routeId"],
      schedule_date_ms: data["scheduleDate"],
      service_ids: data["serviceIds"],
      stop_ids: data["stopIds"],
      trips: Enum.map(data["trips"], &listed_trip/1)
    }
  end

  defp listed_trip(trip) do
    %{
      id: trip["id"],
      direction_id: trip["directionId"],
      headsign: trip["headsign"],
      block_id: trip["blockId"],
      service_id: trip["serviceId"],
      shape_id: trip["shapeId"],
      stop_indexes: trip["stopIndexes"],
      arrival_s: trip["arrivalS"],
      departure_s: trip["departureS"],
      arrival_enabled: trip["arrivalEnabled"],
      departure_enabled: trip["departureEnabled"]
    }
  end
end
