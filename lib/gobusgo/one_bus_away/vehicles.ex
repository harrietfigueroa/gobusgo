defmodule Gobusgo.OneBusAway.Vehicles do
  @moduledoc """
  Requester for the active vehicles of one agency (`vehicles-for-agency`).

  Documented outcomes return as values; payloads that break the documented
  contract raise `Gobusgo.Assert.AssertionError`. The requester returns what
  it fetched and stores nothing.

  ## Usage

      {:ok, settings} = Gobusgo.Config.one_bus_away()

      case Gobusgo.OneBusAway.Vehicles.fetch_response(settings, agency_id: "40") do
        {:ok, response} -> Enum.map(response.vehicles, & &1.id)
        {:error, reason} -> reason
      end

  ## Results

  `{:ok, response}`, where `response` holds the `:agency_id` asked for, the
  `:vehicles` as `t:Gobusgo.OneBusAway.VehicleBatch.Records.vehicle/0`
  values in response order, the whole decoded `:envelope`, the
  `:http_status`, the `:method` and `:host` of the request, and
  `:fetched_at`, the UTC time the response arrived. The API key is replaced
  wherever the server echoes it, and the host carries no credentials.

  Errors are those of `Gobusgo.OneBusAway.Client.get/3` and
  `Gobusgo.OneBusAway.Envelope.interpret/2`.

  Options: `:agency_id` (required), `:clock`, a zero-arity function returning
  the current UTC `DateTime`, and those of `Gobusgo.OneBusAway.Client.get/3`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.OneBusAway.Envelope
  alias Gobusgo.OneBusAway.VehicleBatch.Records
  alias Gobusgo.Schema

  # https://developer.onebusaway.org/api/where/methods/vehicles-for-agency — checked 2026-10-02
  @path_prefix "/api/where/vehicles-for-agency/"
  @path_suffix ".json"
  @method "GET"
  @vehicle_count_max 5_000

  @type response :: %{
          agency_id: String.t(),
          vehicles: [Records.vehicle()],
          envelope: %{String.t() => term()},
          fetched_at: DateTime.t(),
          host: String.t(),
          http_status: 200,
          method: String.t()
        }
  @type error :: Client.failure() | Envelope.failure()
  @type parse_error ::
          {:schema_mismatch, Schema.mismatch()}
          | {:vehicle_count_exceeded, pos_integer()}
          | {:invalid_vehicle, non_neg_integer()}
          | {:duplicate_vehicle, String.t()}

  @coordinates_schema {:map, %{"lat" => :number, "lon" => :number}}

  # The Puget Sound server sends `tripStatus` only for a vehicle serving a
  # trip, and `location` only once the vehicle has reported one; both are
  # absent keys otherwise, never null (observed in every agency's live
  # response, 2026-10-02). Every trip status holds `scheduleDeviation` and
  # `nextStopTimeOffset` as whole seconds and `nextStop` as a stop identifier
  # (observed in the newest stored response of every agency, 2026-10-06).
  # `serviceDate` is "time, in ms since the unix epoch, of midnight for start
  # of the service date for the trip"; every one of 228,621 stored trip
  # statuses of 2026-10-05 to 2026-11-09 held it as an integer, each a
  # midnight in America/Los_Angeles.
  # https://developer.onebusaway.org/api/where/elements/trip-status — checked 2026-11-09
  @vehicle_schema {:map,
                   %{
                     "vehicleId" => :string,
                     "lastUpdateTime" => :integer,
                     "lastLocationUpdateTime" => :integer,
                     "location" => {:optional, @coordinates_schema},
                     "tripStatus" =>
                       {:optional,
                        {:map,
                         %{
                           "activeTripId" => :string,
                           "position" => @coordinates_schema,
                           "orientation" => :number,
                           "lastKnownOrientation" => :number,
                           "predicted" => :boolean,
                           "scheduleDeviation" => :integer,
                           "nextStop" => :string,
                           "nextStopTimeOffset" => :integer,
                           "serviceDate" => :integer
                         }}}
                   }}

  # The Puget Sound server sends the trip of every `activeTripId` and the
  # route of every such trip in `references`, each name a string that is
  # empty when the route or the trip has none (observed in 1,570 stored
  # responses of all 12 agencies, 2026-10-05).
  @references_schema {:map,
                      %{
                        "trips" =>
                          {:list,
                           {:map,
                            %{
                              "id" => :string,
                              "routeId" => :string,
                              "tripHeadsign" => :string
                            }}},
                        "routes" =>
                          {:list,
                           {:map,
                            %{
                              "id" => :string,
                              "shortName" => :string,
                              "longName" => :string
                            }}}
                      }}

  @data_schema {:map,
                %{
                  "limitExceeded" => {:literal, false},
                  "list" => {:list, @vehicle_schema},
                  "references" => @references_schema
                }}

  @doc """
  Fetches the active vehicles of one agency and returns them together with
  the decoded envelope and the facts of the retrieval.
  """
  @spec fetch_response(Client.settings(), Keyword.t()) :: {:ok, response()} | {:error, error()}
  def fetch_response(%{api_key: api_key} = settings, options) when is_list(options) do
    {agency_id, options} = Keyword.pop!(options, :agency_id)
    {clock, client_options} = Keyword.pop(options, :clock, &DateTime.utc_now/0)
    Assert.condition(is_binary(agency_id), "agency identifier must be a string")
    Assert.condition(agency_id != "", "agency identifier must be non-empty")
    Assert.condition(is_function(clock, 0), "clock must be a zero-arity function")

    case Client.get(settings, path(agency_id), client_options) do
      {:ok, %{status: status} = client_response} ->
        fetched_at = clock.()

        with {:ok, envelope} <- Envelope.interpret(client_response, api_key) do
          {:ok,
           %{
             agency_id: agency_id,
             vehicles: parse_data(envelope["data"]),
             envelope: envelope,
             fetched_at: fetched_at,
             host: Client.host(settings),
             http_status: status,
             method: @method
           }}
        end

      {:error, failure} ->
        {:error, failure}
    end
  end

  defp path(agency_id) do
    @path_prefix <> URI.encode(agency_id, &URI.char_unreserved?/1) <> @path_suffix
  end

  @doc """
  Returns the vehicles in `data`, the `data` member of a decoded envelope, in
  response order, or the first way `data` breaks the contract the live server
  keeps. A field the vehicle lacks is `nil`, as is a next stop the trip status
  names with an empty identifier. The route and the headsign of a
  vehicle come from the trip and the route that `data`'s references hold for
  its active trip; one the references lack, and a name that is empty, is
  `nil`. Pure.
  """
  @spec parse(term()) :: {:ok, [Records.vehicle()]} | {:error, parse_error()}
  def parse(data) do
    case Schema.mismatch(data, @data_schema) do
      nil -> parse_list(data)
      mismatch -> {:error, {:schema_mismatch, mismatch}}
    end
  end

  defp parse_list(%{"list" => list, "references" => references}) do
    count = length(list)

    if count <= @vehicle_count_max do
      check_vehicles(list, references)
    else
      {:error, {:vehicle_count_exceeded, count}}
    end
  end

  defp check_vehicles(list, references) do
    case Enum.find_index(list, &(not valid_vehicle?(&1))) do
      nil -> check_identifiers(list, references)
      index -> {:error, {:invalid_vehicle, index}}
    end
  end

  # The rules the schema cannot express: the identifier is non-empty, both
  # times are zero or later, zero being the source's value for "never", and
  # a service date is zero or later.
  defp valid_vehicle?(%{"vehicleId" => id} = vehicle) do
    if id == "" do
      false
    else
      times_valid? = vehicle["lastUpdateTime"] >= 0 and vehicle["lastLocationUpdateTime"] >= 0
      times_valid? and service_date_valid?(vehicle["tripStatus"])
    end
  end

  defp service_date_valid?(nil), do: true
  defp service_date_valid?(%{"serviceDate" => service_date_ms}), do: service_date_ms >= 0

  defp check_identifiers(list, references) do
    duplicate =
      list
      |> Enum.frequencies_by(& &1["vehicleId"])
      |> Enum.find(fn {_id, count} -> count > 1 end)

    case duplicate do
      nil -> {:ok, vehicles(list, references)}
      {id, _count} -> {:error, {:duplicate_vehicle, id}}
    end
  end

  defp vehicles(list, %{"trips" => trips, "routes" => routes}) do
    references = %{
      trips: Map.new(trips, &{&1["id"], &1}),
      routes: Map.new(routes, &{&1["id"], &1})
    }

    Enum.map(list, &vehicle(&1, references))
  end

  defp name(nil), do: nil
  defp name(""), do: nil
  defp name(name) when is_binary(name), do: name

  # `location` and `lastLocationUpdateTime` are the last location the vehicle
  # reported and its time, and the Puget Sound server sends them for vehicles
  # without a trip as well (observed 2026-10-02). The two come from one
  # report, so they are read together and never with the trip status's
  # `lastKnownLocation`, which held a newer report in 900 of 174,774 stored
  # trip statuses of 2026-10-05 to 2026-11-09 that held both.
  defp vehicle(%{"vehicleId" => id} = vehicle, %{trips: trips, routes: routes}) do
    trip_status = vehicle["tripStatus"]
    active_trip_id = trip_status_field(trip_status, "activeTripId")
    trip = Map.get(trips, active_trip_id, %{})
    route = Map.get(routes, trip["routeId"], %{})

    %{
      id: id,
      active_trip_id: active_trip_id,
      route_id: trip["routeId"],
      route_short_name: name(route["shortName"]),
      route_long_name: name(route["longName"]),
      trip_headsign: name(trip["tripHeadsign"]),
      position: coordinates(trip_status_field(trip_status, "position")),
      orientation: trip_status_field(trip_status, "orientation"),
      last_known_location: coordinates(vehicle["location"]),
      last_known_orientation: trip_status_field(trip_status, "lastKnownOrientation"),
      last_update_time_ms: vehicle["lastUpdateTime"],
      last_location_update_time_ms: vehicle["lastLocationUpdateTime"],
      predicted: trip_status_field(trip_status, "predicted"),
      schedule_deviation_seconds: trip_status_field(trip_status, "scheduleDeviation"),
      next_stop_id: name(trip_status_field(trip_status, "nextStop")),
      next_stop_time_offset_seconds: trip_status_field(trip_status, "nextStopTimeOffset"),
      service_date_ms: trip_status_field(trip_status, "serviceDate")
    }
  end

  defp trip_status_field(nil, _field), do: nil
  defp trip_status_field(trip_status, field), do: Map.fetch!(trip_status, field)

  defp coordinates(nil), do: nil
  defp coordinates(%{"lat" => lat, "lon" => lon}), do: %{lat: lat, lon: lon}

  defp parse_data(data) do
    case parse(data) do
      {:ok, vehicles} ->
        vehicles

      {:error, {:schema_mismatch, %{path: path} = cause}} ->
        raise Assert.AssertionError,
          message: "schema mismatch at #{Schema.format_path(path)}",
          cause: cause

      {:error, {:vehicle_count_exceeded, count}} ->
        raise Assert.AssertionError,
          message: "vehicle count #{count} exceeds #{@vehicle_count_max}"

      {:error, {:invalid_vehicle, index}} ->
        raise Assert.AssertionError,
          message:
            "vehicle at index #{index} has an empty identifier, a time before zero," <>
              " or a service date before zero"

      {:error, {:duplicate_vehicle, id}} ->
        raise Assert.AssertionError, message: "vehicle identifier #{inspect(id)} repeats"
    end
  end
end
