defmodule Gobusgo.OneBusAway.RouteSchedules do
  @moduledoc """
  Requester for the schedule of one route on one service date
  (`schedule-for-route`).

  Documented outcomes return as values; payloads that break the documented
  contract raise `Gobusgo.Assert.AssertionError`. The requester returns what
  it fetched and stores nothing.

  ## Usage

      {:ok, settings} = Gobusgo.Config.one_bus_away()
      options = [route_id: "1_100512", service_date: ~D[2026-11-09]]

      case Gobusgo.OneBusAway.RouteSchedules.fetch_response(settings, options) do
        {:ok, %{schedule: :no_service}} -> :no_service
        {:ok, %{schedule: schedule}} -> schedule.trips
        {:error, reason} -> reason
      end

  ## Results

  `{:ok, response}`, where `response` holds the `:route_id` and
  `:service_date` asked for, the `:schedule` as a `t:schedule/0`, or
  `:no_service` for a route with no service on that date, the whole decoded
  `:envelope`, the `:http_status`, the `:method` and `:host` of the request,
  and `:fetched_at`, the UTC time the response arrived. The API key is
  replaced wherever the server echoes it, and the host carries no
  credentials.

  Errors are those of `Gobusgo.OneBusAway.Client.get/3` and
  `Gobusgo.OneBusAway.Envelope.interpret/2`, but for the envelope code that
  says a route has no service on the date.

  Options: `:route_id` and `:service_date` (required), `:clock`, a
  zero-arity function returning the current UTC `DateTime`, and those of
  `Gobusgo.OneBusAway.Client.get/3` other than `:params`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.OneBusAway.Envelope
  alias Gobusgo.Schema

  # https://developer.onebusaway.org/api/where/methods/schedule-for-route — checked 2026-11-08
  @path_prefix "/api/where/schedule-for-route/"
  @path_suffix ".json"
  @method "GET"
  # The method's alternate code for "the route has no schedules for the day
  # requested", whose text the live server sends as "NoServiceThatDay".
  # https://developer.onebusaway.org/api/where/methods/schedule-for-route — checked 2026-11-08
  @no_service_code 510

  # The live server's largest route on 2026-11-07 had 234 trips, its longest
  # trip 93 stop times, and its latest time 106,200 seconds, 29:30.
  @trip_count_max 2_000
  @stop_time_count_max 500
  @seconds_per_day 86_400
  @time_s_max 2 * @seconds_per_day

  @typedoc """
  One stop of a trip. The times are seconds from the start of the service
  day, which is the unit the live server's values fit, so a stop past
  midnight is past #{@seconds_per_day}; the method's documentation states no
  unit for them. `arrival_enabled` and `departure_enabled` say whether
  riders may leave and board there.
  """
  @type stop_time :: %{
          stop_id: String.t(),
          arrival_s: non_neg_integer(),
          departure_s: non_neg_integer(),
          arrival_enabled: boolean(),
          departure_enabled: boolean()
        }

  @typedoc """
  One trip of the route on the date, with its stop times in the order it
  serves them. `headsign`, `block_id`, and `shape_id` are `nil` when the
  source sends them empty.
  """
  @type trip :: %{
          id: String.t(),
          direction_id: String.t(),
          headsign: String.t() | nil,
          block_id: String.t() | nil,
          service_id: String.t(),
          shape_id: String.t() | nil,
          stop_times: [stop_time(), ...]
        }

  @typedoc """
  The schedule of one route on one service date. `schedule_date_ms` is the
  start of the service date the source answered for, in milliseconds since
  the Unix epoch, and `service_ids` the services it found running that date,
  calendar exceptions applied.
  """
  @type schedule :: %{
          route_id: String.t(),
          schedule_date_ms: integer(),
          service_ids: [String.t()],
          trips: [trip()]
        }

  @type response :: %{
          route_id: String.t(),
          service_date: Date.t(),
          schedule: schedule() | :no_service,
          envelope: %{String.t() => term()},
          fetched_at: DateTime.t(),
          host: String.t(),
          http_status: 200,
          method: String.t()
        }
  @type error :: Client.failure() | Envelope.failure()
  @type parse_error ::
          {:schema_mismatch, Schema.mismatch()}
          | {:route_mismatch, String.t()}
          | {:trip_count_exceeded, pos_integer()}
          | {:duplicate_trip, String.t()}
          | {:unreferenced_trip, String.t()}
          | {:stop_time_count_out_of_range, String.t()}
          | {:stop_time_trip_mismatch, String.t()}
          | {:time_out_of_range, String.t()}
          | {:arrival_after_departure, String.t()}
          | {:unordered_stop_times, String.t()}

  @stop_time_schema {:map,
                     %{
                       "stopId" => :string,
                       "tripId" => :string,
                       "arrivalTime" => :integer,
                       "departureTime" => :integer,
                       "arrivalEnabled" => :boolean,
                       "departureEnabled" => :boolean
                     }}

  # The Puget Sound server sent every field below for every trip of the 272
  # routes with service on 2026-11-07, a string empty where the agency
  # supplies nothing. `timeZone` was always empty and is not read.
  @trip_schema {:map,
                %{
                  "id" => :string,
                  "directionId" => :string,
                  "tripHeadsign" => :string,
                  "blockId" => :string,
                  "serviceId" => :string,
                  "shapeId" => :string
                }}

  @data_schema {:map,
                %{
                  "entry" =>
                    {:map,
                     %{
                       "routeId" => :string,
                       "scheduleDate" => :integer,
                       "serviceIds" => {:list, :string},
                       "stopTripGroupings" =>
                         {:list,
                          {:map,
                           %{
                             "tripsWithStopTimes" =>
                               {:list,
                                {:map,
                                 %{"tripId" => :string, "stopTimes" => {:list, @stop_time_schema}}}}
                           }}}
                     }},
                  "references" => {:map, %{"trips" => {:list, @trip_schema}}}
                }}

  @doc """
  Fetches the schedule of one route on one service date and returns it
  together with the decoded envelope and the facts of the retrieval.
  """
  @spec fetch_response(Client.settings(), Keyword.t()) :: {:ok, response()} | {:error, error()}
  def fetch_response(%{api_key: api_key} = settings, options) when is_list(options) do
    {route_id, options} = Keyword.pop!(options, :route_id)
    {service_date, options} = Keyword.pop!(options, :service_date)
    {clock, client_options} = Keyword.pop(options, :clock, &DateTime.utc_now/0)
    Assert.condition(is_binary(route_id), "route identifier must be a string")
    Assert.condition(route_id != "", "route identifier must be non-empty")
    Assert.condition(is_struct(service_date, Date), "service date must be a Date")
    Assert.condition(is_function(clock, 0), "clock must be a zero-arity function")
    Assert.condition(Keyword.get(client_options, :params) == nil, "params are the requester's")
    client_options = Keyword.put(client_options, :params, date: Date.to_iso8601(service_date))

    case Client.get(settings, path(route_id), client_options) do
      {:ok, %{status: status} = client_response} ->
        fetched_at = clock.()
        request = %{route_id: route_id, service_date: service_date}

        with {:ok, envelope, schedule} <-
               interpret(%{response: client_response, api_key: api_key, route_id: route_id}) do
          {:ok,
           Map.merge(request, %{
             schedule: schedule,
             envelope: envelope,
             fetched_at: fetched_at,
             host: Client.host(settings),
             http_status: status,
             method: @method
           })}
        end

      {:error, failure} ->
        {:error, failure}
    end
  end

  defp interpret(%{response: response, api_key: api_key, route_id: route_id}) do
    case Envelope.interpret(response, api_key) do
      {:ok, envelope} ->
        {:ok, envelope, parse_data(envelope["data"], route_id)}

      {:error, {:api_error, %{code: @no_service_code}}} ->
        {:ok, envelope_of(response, api_key), :no_service}

      {:error, failure} ->
        {:error, failure}
    end
  end

  # The envelope of a response that carries an alternate code, scrubbed of
  # the key as a success's is.
  defp envelope_of(%{body: body}, api_key) do
    {:ok, decoded} = JSON.decode(body)
    Client.scrub(decoded, api_key)
  end

  defp path(route_id) do
    @path_prefix <> URI.encode(route_id, &URI.char_unreserved?/1) <> @path_suffix
  end

  @doc """
  Returns the schedule in `data`, the `data` member of a decoded envelope
  fetched for `route_id`, or the first way `data` breaks the contract the
  live server keeps. A field the source sends empty is `nil`. Pure.
  """
  @spec parse(term(), String.t()) :: {:ok, schedule()} | {:error, parse_error()}
  def parse(data, route_id) when is_binary(route_id) do
    case Schema.mismatch(data, @data_schema) do
      nil -> parse_entry(data["entry"], data["references"]["trips"], route_id)
      mismatch -> {:error, {:schema_mismatch, mismatch}}
    end
  end

  defp parse_entry(%{"routeId" => entry_route_id} = entry, references, route_id) do
    if entry_route_id == route_id do
      listed =
        for grouping <- entry["stopTripGroupings"],
            trip <- grouping["tripsWithStopTimes"],
            do: trip

      with :ok <- check_trips(listed, references),
           :ok <- check_stop_times(listed) do
        {:ok, schedule(entry, listed, references)}
      end
    else
      {:error, {:route_mismatch, entry_route_id}}
    end
  end

  defp check_trips(listed, references) do
    trip_ids = Enum.map(listed, & &1["tripId"])
    referenced = MapSet.new(references, & &1["id"])

    cond do
      length(trip_ids) > @trip_count_max ->
        {:error, {:trip_count_exceeded, length(trip_ids)}}

      duplicate = first_duplicate(trip_ids) ->
        {:error, {:duplicate_trip, duplicate}}

      missing = Enum.find(trip_ids, &(not MapSet.member?(referenced, &1))) ->
        {:error, {:unreferenced_trip, missing}}

      true ->
        :ok
    end
  end

  defp first_duplicate(ids) do
    ids
    |> Enum.frequencies()
    |> Enum.find_value(fn {id, count} -> if count > 1, do: id end)
  end

  defp check_stop_times(listed) do
    Enum.find_value(listed, :ok, fn %{"tripId" => trip_id, "stopTimes" => stop_times} ->
      case stop_time_violation(trip_id, stop_times) do
        nil -> nil
        reason -> {:error, {reason, trip_id}}
      end
    end)
  end

  # The rules the schema cannot express, in the order they are checked: a
  # trip has stop times within the bound and all of them its own; each time
  # lies within two service days; a stop departs no earlier than it is
  # reached; and the trip reaches each stop no earlier than it left the last.
  defp stop_time_violation(trip_id, stop_times) do
    count = length(stop_times)
    times = Enum.flat_map(stop_times, &[&1["arrivalTime"], &1["departureTime"]])

    cond do
      count < 1 or count > @stop_time_count_max ->
        :stop_time_count_out_of_range

      Enum.any?(stop_times, &(&1["tripId"] != trip_id)) ->
        :stop_time_trip_mismatch

      Enum.any?(times, &(&1 < 0 or &1 >= @time_s_max)) ->
        :time_out_of_range

      Enum.any?(stop_times, &(&1["arrivalTime"] > &1["departureTime"])) ->
        :arrival_after_departure

      times != Enum.sort(times) ->
        :unordered_stop_times

      true ->
        nil
    end
  end

  defp schedule(entry, listed, references) do
    references_by_id = Map.new(references, &{&1["id"], &1})

    %{
      route_id: entry["routeId"],
      schedule_date_ms: entry["scheduleDate"],
      service_ids: entry["serviceIds"],
      trips: for(listed_trip <- listed, do: trip(listed_trip, references_by_id))
    }
  end

  defp trip(%{"tripId" => trip_id, "stopTimes" => stop_times}, references_by_id) do
    reference = Map.fetch!(references_by_id, trip_id)

    %{
      id: trip_id,
      direction_id: reference["directionId"],
      headsign: supplied(reference["tripHeadsign"]),
      block_id: supplied(reference["blockId"]),
      service_id: reference["serviceId"],
      shape_id: supplied(reference["shapeId"]),
      stop_times: Enum.map(stop_times, &stop_time/1)
    }
  end

  defp stop_time(stop_time) do
    %{
      stop_id: stop_time["stopId"],
      arrival_s: stop_time["arrivalTime"],
      departure_s: stop_time["departureTime"],
      arrival_enabled: stop_time["arrivalEnabled"],
      departure_enabled: stop_time["departureEnabled"]
    }
  end

  defp supplied(""), do: nil
  defp supplied(value) when is_binary(value), do: value

  defp parse_data(data, route_id) do
    case parse(data, route_id) do
      {:ok, schedule} ->
        schedule

      {:error, {:schema_mismatch, %{path: path} = cause}} ->
        raise Assert.AssertionError,
          message: "schema mismatch at #{Schema.format_path(path)}",
          cause: cause

      {:error, reason} ->
        raise Assert.AssertionError, message: parse_error_message(reason)
    end
  end

  defp parse_error_message({:route_mismatch, entry_route_id}),
    do: "response is for route #{inspect(entry_route_id)}, another than the one asked for"

  defp parse_error_message({:trip_count_exceeded, count}),
    do: "trip count #{count} exceeds #{@trip_count_max}"

  defp parse_error_message({:duplicate_trip, id}), do: "trip #{inspect(id)} is listed twice"
  defp parse_error_message({:unreferenced_trip, id}), do: "trip #{inspect(id)} has no reference"

  defp parse_error_message({:stop_time_count_out_of_range, id}),
    do: "trip #{inspect(id)} has no stop times or more than #{@stop_time_count_max}"

  defp parse_error_message({:stop_time_trip_mismatch, id}),
    do: "trip #{inspect(id)} lists a stop time of another trip"

  defp parse_error_message({:time_out_of_range, id}),
    do: "trip #{inspect(id)} has a time outside 0 to #{@time_s_max} seconds"

  defp parse_error_message({:arrival_after_departure, id}),
    do: "trip #{inspect(id)} reaches a stop after it leaves it"

  defp parse_error_message({:unordered_stop_times, id}),
    do: "trip #{inspect(id)} goes back in time between its stops"
end
