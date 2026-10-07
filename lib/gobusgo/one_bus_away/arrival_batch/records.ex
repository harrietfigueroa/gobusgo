defmodule Gobusgo.OneBusAway.ArrivalBatch.Records do
  alias Gobusgo.CloudEvent

  @topic "oba.arrivals.state"
  @source "/gobusgo/processor/oba/arrivals-and-departures-for-stop"
  @key_prefix "arrivals/"
  @type_name CloudEvent.type(%{name: "stop.arrivals.processed", version: 1})

  @moduledoc """
  The published form of one fetch of the arrivals at a stop: one record that
  holds every arrival of the fetch. Everything here is pure, so the record
  is a function of the stored response alone and a repeated build yields the
  same bytes.

  The record goes to the topic `#{@topic}` and holds one
  `Gobusgo.CloudEvent` whose `source` is `#{@source}` and whose `time` is
  the fetch time.

    * Key: `#{@key_prefix}<stop id>`, so a stop's newest record replaces its
      earlier ones.
    * `type`: `#{@type_name}`.
    * `id`: `<requestId>/#{@key_prefix}<stop id>`.
    * `subject`: the stop identifier.
    * `data.stopId`: the stop.
    * `data.arrivals`: the arrivals in the source's order, each with the
      fields below.
    * `data.dataSha256`: the data hash of the stored response.
    * `data.destination`: the destination of the stored response.
    * `data.fetchedAt`: the fetch time in UTC extended ISO 8601.
    * `data.requestId`: the request identifier of the fetch.

  An arrival always holds every one of these keys, a field the source did
  not supply as `null`. Times are milliseconds since the Unix epoch.

    * `tripId`, `serviceDateMs`, `stopSequence`: the trip, its service
      date, and which of the trip's stops this is. The source lists a trip
      twice when it matches two vehicles to it, so the three together do
      not identify an arrival.
    * `routeId`, `routeShortName`, `routeLongName`, `tripHeadsign`: the
      route and what the trip shows to riders.
    * `arrivalEnabled`, `departureEnabled`: whether riders can arrive and
      depart on it here.
    * `scheduledArrivalTimeMs`, `scheduledDepartureTimeMs`: the schedule.
    * `predicted`: whether the source has real-time data for the trip.
    * `predictedArrivalTimeMs`, `predictedDepartureTimeMs`: the source's
      predictions, `null` where it has none that can be shown.
    * `vehicleId`: the vehicle the source matches to the trip.
    * `vehicleScheduleDeviationSeconds`: how late that vehicle was on this
      trip at the fetch, negative when early, and `null` while the vehicle
      serves another trip.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.RawArrivalResponse
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId
  alias Gobusgo.Schema

  @typedoc """
  What one record holds. `id` is the stop identifier, and `arrivals` are the
  JSON values of `data.arrivals`, limited to the fields this module
  documents.
  """
  @type decoded :: %{
          id: String.t(),
          request_id: RequestId.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          destination: String.t(),
          arrivals: [%{String.t() => term()}]
        }

  @typedoc """
    * `:invalid_json` — the value is not JSON.
    * `:schema_mismatch` — the value is not a record `build/1` produces.
    * `:unsupported_type` — the value is an event of another `type`.
  """
  @type decode_error :: :invalid_json | :schema_mismatch | :unsupported_type

  @arrival_schema {:map,
                   %{
                     "tripId" => :string,
                     "serviceDateMs" => :integer,
                     "stopSequence" => :integer,
                     "routeId" => :string,
                     "routeShortName" => {:nullable, :string},
                     "routeLongName" => {:nullable, :string},
                     "tripHeadsign" => {:nullable, :string},
                     "arrivalEnabled" => :boolean,
                     "departureEnabled" => :boolean,
                     "scheduledArrivalTimeMs" => :integer,
                     "scheduledDepartureTimeMs" => :integer,
                     "predicted" => :boolean,
                     "predictedArrivalTimeMs" => {:nullable, :integer},
                     "predictedDepartureTimeMs" => {:nullable, :integer},
                     "vehicleId" => {:nullable, :string},
                     "vehicleScheduleDeviationSeconds" => {:nullable, :integer}
                   }}

  @arrival_fields @arrival_schema |> elem(1) |> Map.keys()

  @data_schema {:map,
                %{
                  "stopId" => :string,
                  "arrivals" => {:list, @arrival_schema},
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
  `Gobusgo.OneBusAway.RawArrivalResponse.parse/1` returns it. Raises
  `Gobusgo.Assert.AssertionError` when the request identifier is not a UUID
  version 7, the stop identifier is empty, or an arrival is not a
  `t:Gobusgo.OneBusAway.Arrivals.arrival/0`.
  """
  @spec build(RawArrivalResponse.parsed()) :: Publisher.topic_record()
  def build(%{request_id: request_id, fetched_at: %DateTime{} = fetched_at} = parsed) do
    %{stop_id: stop_id, arrivals: arrivals} = parsed
    Assert.condition(RequestId.valid?(request_id), "request identifier must be a UUID version 7")
    Assert.condition(is_binary(stop_id), "stop identifier must be a string")
    Assert.condition(stop_id != "", "stop identifier must be non-empty")
    key = @key_prefix <> stop_id

    data = %{
      "stopId" => stop_id,
      "arrivals" => Enum.map(arrivals, &arrival_data/1),
      "dataSha256" => parsed.data_sha256,
      "destination" => parsed.destination,
      "fetchedAt" => DateTime.to_iso8601(fetched_at, :extended),
      "requestId" => request_id
    }

    Assert.schema(data, @data_schema)

    CloudEvent.record(@topic, %{
      id: request_id <> "/" <> key,
      source: @source,
      type: @type_name,
      time: fetched_at,
      subject: stop_id,
      partition_key: key,
      data: data
    })
  end

  defp arrival_data(arrival) do
    %{
      "tripId" => arrival.trip_id,
      "serviceDateMs" => arrival.service_date_ms,
      "stopSequence" => arrival.stop_sequence,
      "routeId" => arrival.route_id,
      "routeShortName" => arrival.route_short_name,
      "routeLongName" => arrival.route_long_name,
      "tripHeadsign" => arrival.trip_headsign,
      "arrivalEnabled" => arrival.arrival_enabled,
      "departureEnabled" => arrival.departure_enabled,
      "scheduledArrivalTimeMs" => arrival.scheduled_arrival_time_ms,
      "scheduledDepartureTimeMs" => arrival.scheduled_departure_time_ms,
      "predicted" => arrival.predicted,
      "predictedArrivalTimeMs" => arrival.predicted_arrival_time_ms,
      "predictedDepartureTimeMs" => arrival.predicted_departure_time_ms,
      "vehicleId" => arrival.vehicle_id,
      "vehicleScheduleDeviationSeconds" => arrival.vehicle_schedule_deviation_seconds
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
         %{"stopId" => stop_id, "requestId" => request_id} = data,
         true <- stop_id != "",
         true <- RequestId.valid?(request_id),
         {:ok, fetched_at, 0} <- DateTime.from_iso8601(data["fetchedAt"]) do
      {:ok,
       %{
         id: stop_id,
         request_id: request_id,
         fetched_at: fetched_at,
         data_sha256: data["dataSha256"],
         destination: data["destination"],
         arrivals: Enum.map(data["arrivals"], &Map.take(&1, @arrival_fields))
       }}
    else
      _mismatch -> {:error, :schema_mismatch}
    end
  end
end
