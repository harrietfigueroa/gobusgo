defmodule Gobusgo.OneBusAway.VehicleBatch.Records do
  alias Gobusgo.CloudEvent

  @topic "oba.vehicles-for-agency.state"
  @source "/gobusgo/processor/oba/vehicles-for-agency"
  @vehicle_key_prefix "vehicle/"
  @manifest_key_prefix "manifest/"
  @vehicle_type CloudEvent.type(%{name: "vehicle.processed", version: 1})
  @manifest_type CloudEvent.type(%{name: "vehicle.fetch.completed", version: 1})

  @moduledoc """
  The published form of one agency's vehicle fetch: one record per vehicle
  and one manifest record that completes the fetch. Everything here is pure,
  so the records are a function of the fetch alone and a repeated build
  yields the same bytes.

  Every record goes to the topic `#{@topic}` and holds one
  `Gobusgo.CloudEvent` whose `source` is `#{@source}` and whose `time` is
  the fetch time.

  ## Vehicle record

  One per vehicle, in identifier order.

    * Key: `#{@vehicle_key_prefix}<agency id>/<vehicle id>`.
    * `type`: `#{@vehicle_type}`.
    * `id`: `<requestId>/#{@vehicle_key_prefix}<agency id>/<vehicle id>`.
    * `subject`: the vehicle identifier.
    * `data.vehicle`: the fields below.
    * `data.fetchedAt`: the fetch time in UTC extended ISO 8601.
    * `data.requestId`: the request identifier of the fetch.

  `data.vehicle` always holds every one of these keys. `id` and `agencyId`
  are non-empty strings; every other field is `null` when the source did not
  supply it.

    * `id`: the vehicle identifier.
    * `agencyId`: the agency the fetch asked for.
    * `activeTripId`: the trip the vehicle serves.
    * `routeId`: the route of that trip.
    * `routeShortName`: the short name of that route, such as a route
      number.
    * `routeLongName`: the long name of that route.
    * `tripHeadsign`: the destination the trip shows to riders.
    * `position`: `lat` and `lon` of where the source places the vehicle
      now. The source extrapolates it or takes it from the schedule when it
      has no fresh report, so it is an estimate and never a report.
    * `orientation`: the direction that goes with `position`, in degrees.
    * `lastKnownLocation`: `lat` and `lon` of the last location the vehicle
      reported.
    * `lastKnownOrientation`: the last direction the vehicle reported, in
      degrees. The source sends `0` for a vehicle that has reported no
      location as well, so `0` does not always mean due north.
    * `lastUpdateTimeMs`: when the source last heard from the vehicle, in
      milliseconds since the Unix epoch. `0` is the source's value for
      "never".
    * `lastLocationUpdateTimeMs`: when the vehicle last reported a location,
      in milliseconds since the Unix epoch. `0` is the source's value for
      "never", and is kept apart from `null`.
    * `predicted`: whether the source has real-time data for the vehicle's
      trip. It is `true` for a vehicle that has reported no location too,
      so it says nothing about `lastKnownLocation`.
    * `scheduleDeviationSeconds`: how far the vehicle is from its trip's
      schedule, in whole seconds. A positive value is late and a negative
      one early.
    * `nextStopId`: the stop the vehicle reaches next on its trip.
    * `nextStopTimeOffsetSeconds`: the time from the vehicle's position to
      that stop among the trip's stop times, in whole seconds, as of the
      fetch.

  ## Manifest record

  One per fetch.

    * Key: `#{@manifest_key_prefix}<agency id>`.
    * `type`: `#{@manifest_type}`.
    * `id`: `<requestId>/#{@manifest_key_prefix}<agency id>`.
    * `subject`: the destination of the stored response.
    * `data.agencyId`: the agency the fetch asked for.
    * `data.vehicleIds`: the identifier of every vehicle in the fetch, sorted.
    * `data.dataSha256`: the data hash of the stored response.
    * `data.destination`: the destination of the stored response.
    * `data.fetchedAt` and `data.requestId`: as in a vehicle record.

  ## Tombstone record

  One per vehicle whose record is removed from the topic: the vehicle's key
  with an empty value and no headers.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Publisher
  alias Gobusgo.RequestId
  alias Gobusgo.Schema

  @type t :: %{vehicles: [Publisher.topic_record()], manifest: Publisher.topic_record()}

  @type coordinates :: %{lat: number(), lon: number()}

  @typedoc "One vehicle of a fetch. A field the source did not supply is `nil`."
  @type vehicle :: %{
          id: String.t(),
          active_trip_id: String.t() | nil,
          route_id: String.t() | nil,
          route_short_name: String.t() | nil,
          route_long_name: String.t() | nil,
          trip_headsign: String.t() | nil,
          position: coordinates() | nil,
          orientation: number() | nil,
          last_known_location: coordinates() | nil,
          last_known_orientation: number() | nil,
          last_update_time_ms: non_neg_integer() | nil,
          last_location_update_time_ms: non_neg_integer() | nil,
          predicted: boolean() | nil,
          schedule_deviation_seconds: integer() | nil,
          next_stop_id: String.t() | nil,
          next_stop_time_offset_seconds: integer() | nil
        }

  @type fetch :: %{
          agency_id: String.t(),
          destination: String.t(),
          fetched_at: DateTime.t(),
          data_sha256: String.t(),
          request_id: RequestId.t(),
          vehicles: [vehicle()]
        }

  @typedoc """
  What one record holds. A vehicle is the JSON object of `data.vehicle`,
  limited to the fields this module documents.
  """
  @type decoded ::
          {:vehicle,
           %{
             request_id: RequestId.t(),
             fetched_at: DateTime.t(),
             agency_id: String.t(),
             vehicle: %{String.t() => term()}
           }}
          | {:manifest,
             %{
               request_id: RequestId.t(),
               fetched_at: DateTime.t(),
               agency_id: String.t(),
               vehicle_ids: [String.t()],
               data_sha256: String.t(),
               destination: String.t()
             }}

  @typedoc """
    * `:invalid_json` — the value is not JSON.
    * `:schema_mismatch` — the value is not a record `build/1` produces.
    * `:unsupported_type` — the value is an event of another `type`.
  """
  @type decode_error :: :invalid_json | :schema_mismatch | :unsupported_type

  @coordinate_fields ["lat", "lon"]
  @coordinates_fields ["position", "lastKnownLocation"]
  @time_fields ["lastUpdateTimeMs", "lastLocationUpdateTimeMs"]
  @route_fields ["routeId", "routeShortName", "routeLongName", "tripHeadsign"]
  @trip_time_fields ["scheduleDeviationSeconds", "nextStopId", "nextStopTimeOffsetSeconds"]
  @optional_fields @route_fields ++ @trip_time_fields

  @coordinates_schema {:nullable, {:map, %{"lat" => :number, "lon" => :number}}}

  @vehicle_schema {:map,
                   %{
                     "id" => :string,
                     "agencyId" => :string,
                     "activeTripId" => {:nullable, :string},
                     "routeId" => {:optional, {:nullable, :string}},
                     "routeShortName" => {:optional, {:nullable, :string}},
                     "routeLongName" => {:optional, {:nullable, :string}},
                     "tripHeadsign" => {:optional, {:nullable, :string}},
                     "position" => @coordinates_schema,
                     "orientation" => {:nullable, :number},
                     "lastKnownLocation" => @coordinates_schema,
                     "lastKnownOrientation" => {:nullable, :number},
                     "lastUpdateTimeMs" => {:nullable, :integer},
                     "lastLocationUpdateTimeMs" => {:nullable, :integer},
                     "predicted" => {:nullable, :boolean},
                     "scheduleDeviationSeconds" => {:optional, {:nullable, :integer}},
                     "nextStopId" => {:optional, {:nullable, :string}},
                     "nextStopTimeOffsetSeconds" => {:optional, {:nullable, :integer}}
                   }}

  @vehicle_fields @vehicle_schema |> elem(1) |> Map.keys()

  @vehicle_data_schema {:map,
                        %{
                          "vehicle" => @vehicle_schema,
                          "fetchedAt" => :string,
                          "requestId" => :string
                        }}

  @manifest_data_schema {:map,
                         %{
                           "agencyId" => :string,
                           "vehicleIds" => {:list, :string},
                           "dataSha256" => :string,
                           "destination" => :string,
                           "fetchedAt" => :string,
                           "requestId" => :string
                         }}

  @doc "The topic the records go to."
  @spec topic() :: String.t()
  def topic, do: @topic

  @doc """
  Returns the records that publish `fetch`, the vehicles one request for one
  agency returned. Raises `Gobusgo.Assert.AssertionError` when the request
  identifier is not a UUID version 7, the agency identifier is empty, a
  vehicle identifier repeats, or a vehicle is not a `t:vehicle/0`.
  """
  @spec build(fetch()) :: t()
  def build(%{request_id: request_id, fetched_at: %DateTime{} = fetched_at} = fetch) do
    %{agency_id: agency_id, destination: destination, data_sha256: data_sha256} = fetch
    Assert.condition(RequestId.valid?(request_id), "request identifier must be a UUID version 7")
    Assert.condition(is_binary(agency_id), "agency identifier must be a string")
    Assert.condition(agency_id != "", "agency identifier must be non-empty")

    vehicles = Enum.sort_by(fetch.vehicles, & &1.id)
    vehicle_ids = Enum.map(vehicles, & &1.id)
    Assert.condition(vehicle_ids == Enum.dedup(vehicle_ids), "vehicle identifiers must be unique")

    fetch_data = %{
      "fetchedAt" => DateTime.to_iso8601(fetched_at, :extended),
      "requestId" => request_id
    }

    manifest_data =
      Map.merge(fetch_data, %{
        "agencyId" => agency_id,
        "vehicleIds" => vehicle_ids,
        "dataSha256" => data_sha256,
        "destination" => destination
      })

    context = %{
      agency_id: agency_id,
      request_id: request_id,
      fetched_at: fetched_at,
      fetch_data: fetch_data
    }

    %{
      vehicles: Enum.map(vehicles, &vehicle_record(&1, context)),
      manifest:
        record(context, %{
          key: @manifest_key_prefix <> agency_id,
          type: @manifest_type,
          subject: destination,
          data: manifest_data
        })
    }
  end

  @doc """
  Returns the tombstone records of the vehicles `vehicle_ids` of the agency
  `agency_id`, in the order given. Raises `Gobusgo.Assert.AssertionError`
  when an identifier is empty.
  """
  @spec tombstones(%{agency_id: String.t(), vehicle_ids: [String.t()]}) ::
          [Publisher.topic_record()]
  def tombstones(%{agency_id: agency_id, vehicle_ids: vehicle_ids})
      when is_binary(agency_id) and is_list(vehicle_ids) do
    Assert.condition(agency_id != "", "agency identifier must be non-empty")

    for id <- vehicle_ids do
      Assert.condition(is_binary(id), "vehicle identifier must be a string")
      Assert.condition(id != "", "vehicle identifier must be non-empty")
      key = @vehicle_key_prefix <> agency_id <> "/" <> id
      %{topic: @topic, key: key, value: "", headers: []}
    end
  end

  @doc """
  Returns what `value`, the value of a record `build/1` produces, holds. The
  first rule the value breaks returns as a value.
  """
  @spec decode(binary()) :: {:ok, decoded()} | {:error, decode_error()}
  def decode(value) when is_binary(value) do
    with {:ok, %{type: type, data: data}} <- CloudEvent.decode(value) do
      case type do
        @vehicle_type -> decode_vehicle(data)
        @manifest_type -> decode_manifest(data)
        _other -> {:error, :unsupported_type}
      end
    end
  end

  defp decode_vehicle(data) do
    with nil <- Schema.mismatch(data, @vehicle_data_schema),
         {:ok, fetch} <- decode_fetch(data),
         vehicle = data["vehicle"],
         true <- valid_vehicle?(vehicle) do
      %{"agencyId" => agency_id} = vehicle = known_fields(vehicle)
      {:ok, {:vehicle, Map.merge(fetch, %{agency_id: agency_id, vehicle: vehicle})}}
    else
      _mismatch -> {:error, :schema_mismatch}
    end
  end

  defp decode_manifest(data) do
    with nil <- Schema.mismatch(data, @manifest_data_schema),
         {:ok, fetch} <- decode_fetch(data),
         %{"agencyId" => agency_id} = data,
         true <- agency_id != "" do
      {:ok,
       {:manifest,
        Map.merge(fetch, %{
          agency_id: agency_id,
          vehicle_ids: data["vehicleIds"],
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

  # The rules the schema cannot express: the identifiers are non-empty, a
  # supplied time is zero or later, and a supplied next stop is non-empty.
  defp valid_vehicle?(%{"id" => id, "agencyId" => agency_id} = vehicle) do
    if id != "" and agency_id != "" and vehicle["nextStopId"] != "" do
      Enum.all?(@time_fields, &time?(vehicle[&1]))
    else
      false
    end
  end

  defp time?(nil), do: true
  defp time?(time_ms) when is_integer(time_ms), do: time_ms >= 0

  # A record that lacks the route keys or the trip time keys decodes with
  # each of them `nil`, so a decoded vehicle holds every field whatever the
  # record holds.
  defp known_fields(vehicle) do
    vehicle = Map.merge(Map.from_keys(@optional_fields, nil), Map.take(vehicle, @vehicle_fields))

    Enum.reduce(@coordinates_fields, vehicle, fn field, vehicle ->
      Map.update!(vehicle, field, &known_coordinates/1)
    end)
  end

  defp known_coordinates(nil), do: nil
  defp known_coordinates(coordinates), do: Map.take(coordinates, @coordinate_fields)

  defp vehicle_record(%{id: id} = vehicle, %{agency_id: agency_id} = context) do
    vehicle_data = %{
      "id" => id,
      "agencyId" => agency_id,
      "activeTripId" => vehicle.active_trip_id,
      "routeId" => vehicle.route_id,
      "routeShortName" => vehicle.route_short_name,
      "routeLongName" => vehicle.route_long_name,
      "tripHeadsign" => vehicle.trip_headsign,
      "position" => coordinates(vehicle.position),
      "orientation" => vehicle.orientation,
      "lastKnownLocation" => coordinates(vehicle.last_known_location),
      "lastKnownOrientation" => vehicle.last_known_orientation,
      "lastUpdateTimeMs" => vehicle.last_update_time_ms,
      "lastLocationUpdateTimeMs" => vehicle.last_location_update_time_ms,
      "predicted" => vehicle.predicted,
      "scheduleDeviationSeconds" => vehicle.schedule_deviation_seconds,
      "nextStopId" => vehicle.next_stop_id,
      "nextStopTimeOffsetSeconds" => vehicle.next_stop_time_offset_seconds
    }

    Assert.schema(vehicle_data, @vehicle_schema)

    Assert.condition(
      valid_vehicle?(vehicle_data),
      "vehicle must hold an identifier, no time before zero, and no empty next stop"
    )

    record(context, %{
      key: @vehicle_key_prefix <> agency_id <> "/" <> id,
      type: @vehicle_type,
      subject: id,
      data: Map.put(context.fetch_data, "vehicle", vehicle_data)
    })
  end

  defp coordinates(nil), do: nil
  defp coordinates(%{lat: lat, lon: lon}), do: %{"lat" => lat, "lon" => lon}

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
