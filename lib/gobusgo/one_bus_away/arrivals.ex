defmodule Gobusgo.OneBusAway.Arrivals do
  @arrival_count_max 500
  @prediction_offset_ms_max 7_200_000
  @ms_per_minute 60_000

  @moduledoc """
  Requester for the arrivals and departures at one stop
  (`arrivals-and-departures-for-stop`), over the server's default window.

  Documented outcomes return as values; payloads that break the documented
  contract raise `Gobusgo.Assert.AssertionError`. The requester returns what
  it fetched and stores nothing.

  ## Usage

      {:ok, settings} = Gobusgo.Config.one_bus_away()

      case Gobusgo.OneBusAway.Arrivals.fetch_response(settings, stop_id: "1_1471") do
        {:ok, response} -> Enum.map(response.arrivals, & &1.trip_id)
        {:error, reason} -> reason
      end

  ## Results

  `{:ok, response}`, where `response` holds the `:stop_id` asked for, the
  `:arrivals` as `t:arrival/0` values in response order, the whole decoded
  `:envelope`, the `:http_status`, the `:method` and `:host` of the request,
  and `:fetched_at`, the UTC time the response arrived. The API key is
  replaced wherever the server echoes it, and the host carries no
  credentials.

  Errors are those of `Gobusgo.OneBusAway.Client.get/3` and
  `Gobusgo.OneBusAway.Envelope.interpret/2`. A stop the server does not know
  is `{:http_status, 404}`.

  Options: `:stop_id` (required), `:clock`, a zero-arity function returning
  the current UTC `DateTime`, and those of `Gobusgo.OneBusAway.Client.get/3`.

  ## Predictions

  A predicted time is `nil` when the source has none it can be shown by:
  `predicted` is `false`, the time is the source's `0`, or the time is more
  than #{div(@prediction_offset_ms_max, @ms_per_minute)} minutes from its scheduled
  time. The arrival time and the departure time of one arrival are judged
  apart, and `predicted` is passed on as the source sends it.

  The same trip can be listed twice, once per vehicle the source matches to
  it, so nothing here identifies an arrival within a response.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.Client
  alias Gobusgo.OneBusAway.Envelope
  alias Gobusgo.Schema

  # https://developer.onebusaway.org/api/where/methods/arrivals-and-departures-for-stop — checked 2026-10-06
  @path_prefix "/api/where/arrivals-and-departures-for-stop/"
  @path_suffix ".json"
  @method "GET"

  @typedoc """
  One arrival of a trip at the stop. Times are milliseconds since the Unix
  epoch. A name the source sends empty is `nil`, as is the vehicle of an
  arrival no vehicle is matched to. `vehicle_schedule_deviation_seconds` is
  how late the vehicle is on this trip, negative when early, and `nil` when
  the vehicle is not serving this trip yet or the source sends no status.
  """
  @type arrival :: %{
          trip_id: String.t(),
          service_date_ms: non_neg_integer(),
          stop_sequence: non_neg_integer(),
          route_id: String.t(),
          route_short_name: String.t() | nil,
          route_long_name: String.t() | nil,
          trip_headsign: String.t() | nil,
          arrival_enabled: boolean(),
          departure_enabled: boolean(),
          scheduled_arrival_time_ms: pos_integer(),
          scheduled_departure_time_ms: pos_integer(),
          predicted: boolean(),
          predicted_arrival_time_ms: pos_integer() | nil,
          predicted_departure_time_ms: pos_integer() | nil,
          vehicle_id: String.t() | nil,
          vehicle_schedule_deviation_seconds: integer() | nil
        }

  @type response :: %{
          stop_id: String.t(),
          arrivals: [arrival()],
          envelope: %{String.t() => term()},
          fetched_at: DateTime.t(),
          host: String.t(),
          http_status: 200,
          method: String.t()
        }
  @type error :: Client.failure() | Envelope.failure()
  @type parse_error ::
          {:schema_mismatch, Schema.mismatch()}
          | {:stop_mismatch, String.t()}
          | {:arrival_count_exceeded, pos_integer()}
          | {:invalid_arrival, non_neg_integer()}

  # The Puget Sound server sends every key below for every arrival, each
  # name a string that is empty when there is none, and `tripStatus` as an
  # absent key for the few arrivals that have none (observed in 224
  # responses of nine agencies, 489 arrivals, 2026-10-06).
  @arrival_schema {:map,
                   %{
                     "tripId" => :string,
                     "serviceDate" => :integer,
                     "stopSequence" => :integer,
                     "stopId" => :string,
                     "routeId" => :string,
                     "routeShortName" => :string,
                     "routeLongName" => :string,
                     "tripHeadsign" => :string,
                     "arrivalEnabled" => :boolean,
                     "departureEnabled" => :boolean,
                     "scheduledArrivalTime" => :integer,
                     "scheduledDepartureTime" => :integer,
                     "predicted" => :boolean,
                     "predictedArrivalTime" => :integer,
                     "predictedDepartureTime" => :integer,
                     "vehicleId" => :string,
                     "tripStatus" =>
                       {:optional,
                        {:map, %{"activeTripId" => :string, "scheduleDeviation" => :integer}}}
                   }}

  @positive_fields ["serviceDate", "scheduledArrivalTime", "scheduledDepartureTime"]

  @data_schema {:map,
                %{
                  "entry" =>
                    {:map,
                     %{
                       "stopId" => :string,
                       "arrivalsAndDepartures" => {:list, @arrival_schema}
                     }}
                }}

  @doc """
  Fetches the arrivals and departures at one stop and returns them together
  with the decoded envelope and the facts of the retrieval.
  """
  @spec fetch_response(Client.settings(), Keyword.t()) :: {:ok, response()} | {:error, error()}
  def fetch_response(%{api_key: api_key} = settings, options) when is_list(options) do
    {stop_id, options} = Keyword.pop!(options, :stop_id)
    {clock, client_options} = Keyword.pop(options, :clock, &DateTime.utc_now/0)
    Assert.condition(is_binary(stop_id), "stop identifier must be a string")
    Assert.condition(stop_id != "", "stop identifier must be non-empty")
    Assert.condition(is_function(clock, 0), "clock must be a zero-arity function")

    case Client.get(settings, path(stop_id), client_options) do
      {:ok, %{status: status} = client_response} ->
        fetched_at = clock.()

        with {:ok, envelope} <- Envelope.interpret(client_response, api_key) do
          {:ok,
           %{
             stop_id: stop_id,
             arrivals: parse_data(envelope["data"], stop_id),
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

  defp path(stop_id) do
    @path_prefix <> URI.encode(stop_id, &URI.char_unreserved?/1) <> @path_suffix
  end

  @doc """
  Returns the arrivals in `data`, the `data` member of a decoded envelope
  fetched for the stop `stop_id`, in response order, or the first way `data`
  breaks the contract the live server keeps:

    * `{:schema_mismatch, mismatch}`
    * `{:stop_mismatch, stop_id}` — the response is about another stop
    * `{:arrival_count_exceeded, count}` — above #{@arrival_count_max} arrivals
    * `{:invalid_arrival, index}` — an arrival at another stop, with an
      empty trip or route identifier, or with a scheduled time or a service
      date of zero or less

  Pure.
  """
  @spec parse(term(), String.t()) :: {:ok, [arrival()]} | {:error, parse_error()}
  def parse(data, stop_id) when is_binary(stop_id) do
    case Schema.mismatch(data, @data_schema) do
      nil -> parse_entry(data["entry"], stop_id)
      mismatch -> {:error, {:schema_mismatch, mismatch}}
    end
  end

  defp parse_entry(%{"stopId" => entry_stop_id, "arrivalsAndDepartures" => list}, stop_id) do
    count = length(list)

    cond do
      entry_stop_id != stop_id -> {:error, {:stop_mismatch, entry_stop_id}}
      count > @arrival_count_max -> {:error, {:arrival_count_exceeded, count}}
      true -> check_arrivals(list, stop_id)
    end
  end

  defp check_arrivals(list, stop_id) do
    case Enum.find_index(list, &(not valid_arrival?(&1, stop_id))) do
      nil -> {:ok, Enum.map(list, &arrival/1)}
      index -> {:error, {:invalid_arrival, index}}
    end
  end

  # The rules the schema cannot express: the arrival is at the stop asked
  # for, its trip and route are named, its service date and scheduled times
  # are after zero, and its stop sequence is zero or later.
  defp valid_arrival?(%{"stopId" => arrival_stop_id} = arrival, stop_id) do
    if arrival_stop_id == stop_id and arrival["tripId"] != "" and arrival["routeId"] != "" do
      arrival["stopSequence"] >= 0 and
        Enum.all?(@positive_fields, &(Map.fetch!(arrival, &1) > 0))
    else
      false
    end
  end

  defp arrival(%{"tripId" => trip_id, "predicted" => predicted} = arrival) do
    scheduled_arrival_time_ms = arrival["scheduledArrivalTime"]
    scheduled_departure_time_ms = arrival["scheduledDepartureTime"]

    %{
      trip_id: trip_id,
      service_date_ms: arrival["serviceDate"],
      stop_sequence: arrival["stopSequence"],
      route_id: arrival["routeId"],
      route_short_name: name(arrival["routeShortName"]),
      route_long_name: name(arrival["routeLongName"]),
      trip_headsign: name(arrival["tripHeadsign"]),
      arrival_enabled: arrival["arrivalEnabled"],
      departure_enabled: arrival["departureEnabled"],
      scheduled_arrival_time_ms: scheduled_arrival_time_ms,
      scheduled_departure_time_ms: scheduled_departure_time_ms,
      predicted: predicted,
      predicted_arrival_time_ms:
        prediction(%{
          predicted: predicted,
          predicted_time_ms: arrival["predictedArrivalTime"],
          scheduled_time_ms: scheduled_arrival_time_ms
        }),
      predicted_departure_time_ms:
        prediction(%{
          predicted: predicted,
          predicted_time_ms: arrival["predictedDepartureTime"],
          scheduled_time_ms: scheduled_departure_time_ms
        }),
      vehicle_id: name(arrival["vehicleId"]),
      vehicle_schedule_deviation_seconds:
        vehicle_schedule_deviation_seconds(arrival["tripStatus"], trip_id)
    }
  end

  defp name(""), do: nil
  defp name(name) when is_binary(name), do: name

  # The documentation gives a predicted time as "zero if no real-time
  # available". The Puget Sound server also sends, with `predicted` true,
  # times far from the schedule: about 19 hours early for agency `95` and
  # near the epoch for agency `19` (observed 2026-10-06).
  # https://developer.onebusaway.org/api/where/elements/arrival-and-departure — checked 2026-10-06
  defp prediction(%{predicted: false}), do: nil
  defp prediction(%{predicted: true, predicted_time_ms: 0}), do: nil

  defp prediction(%{predicted: true, predicted_time_ms: predicted_time_ms} = times)
       when is_integer(predicted_time_ms) do
    case abs(predicted_time_ms - times.scheduled_time_ms) <= @prediction_offset_ms_max do
      true -> predicted_time_ms
      false -> nil
    end
  end

  # A trip status describes the vehicle's active trip, which is an earlier
  # trip of the block until the vehicle starts this one.
  defp vehicle_schedule_deviation_seconds(nil, _trip_id), do: nil

  defp vehicle_schedule_deviation_seconds(
         %{"activeTripId" => active_trip_id, "scheduleDeviation" => deviation_seconds},
         trip_id
       ) do
    case active_trip_id == trip_id do
      true -> deviation_seconds
      false -> nil
    end
  end

  defp parse_data(data, stop_id) do
    case parse(data, stop_id) do
      {:ok, arrivals} ->
        arrivals

      {:error, {:schema_mismatch, %{path: path} = cause}} ->
        raise Assert.AssertionError,
          message: "schema mismatch at #{Schema.format_path(path)}",
          cause: cause

      {:error, {:stop_mismatch, entry_stop_id}} ->
        raise Assert.AssertionError,
          message: "response is about stop #{inspect(entry_stop_id)}, not #{inspect(stop_id)}"

      {:error, {:arrival_count_exceeded, count}} ->
        raise Assert.AssertionError,
          message: "arrival count #{count} exceeds #{@arrival_count_max}"

      {:error, {:invalid_arrival, index}} ->
        raise Assert.AssertionError,
          message:
            "arrival at index #{index} is at another stop, lacks an identifier, or has a time of zero or less"
    end
  end
end
