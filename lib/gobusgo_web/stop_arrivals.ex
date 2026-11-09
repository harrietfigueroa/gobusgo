defmodule GobusgoWeb.StopArrivals do
  @arrival_count_max 8
  @ms_per_second 1_000
  @ms_per_minute 60_000

  @moduledoc """
  What a map page shows of the arrivals at one stop, from the stop's fetch
  in the arrivals view and the vehicles the vehicle view holds now.
  Everything here is pure, so what a page shows is a function of the two
  and the time it is.

  An arrival's time is its arrival at the stop, or its departure where
  riders cannot arrive on it, which is a trip's first stop. The time is the
  source's prediction when the fetch holds one and the schedule otherwise.

  A prediction is moved by the change in its vehicle's schedule deviation
  since the fetch (decided in GOB-158): a vehicle that is two minutes later
  now than it was at the fetch arrives two minutes later. That needs the
  vehicle's deviation on the arrival's trip at the fetch and the vehicle
  serving the same trip now; an arrival that lacks either keeps its time.

  An arrival's headsign is the source's, without the route's short name
  where the headsign starts with it: "578 Puyallup" on route 578 is
  "Puyallup".

  An arrival whose time has passed is left out. The source lists a trip
  twice when it matches two vehicles to it, and the sooner of the two is
  shown. At most #{@arrival_count_max} arrivals are shown, the soonest
  first.
  """

  alias Gobusgo.OneBusAway.ArrivalBatch
  alias Gobusgo.OneBusAway.VehicleView

  @typedoc """
  One arrival a page shows. `route` is the route's short name, or its long
  name when it has no short name. `headsign` is the trip's, without a
  leading short name of the route. `minutes` is the whole minutes until the
  arrival at the time the line was made, `time_ms` the arrival's time in
  Unix milliseconds, from which a page counts the minutes down itself, and
  `predicted` says whether the time is a prediction or the schedule.
  """
  @type line :: %{
          route: String.t() | nil,
          headsign: String.t() | nil,
          minutes: non_neg_integer(),
          time_ms: integer(),
          predicted: boolean()
        }

  @typedoc """
  What a page shows for a stop: that its arrivals are awaited, or the
  arrivals of a fetch that is `age_minutes` old.
  """
  @type t ::
          %{stop_id: String.t(), status: :waiting}
          | %{
              stop_id: String.t(),
              status: :arrivals,
              age_minutes: non_neg_integer(),
              arrivals: [line()]
            }

  @doc "The most arrivals shown for one stop."
  @spec arrival_count_max() :: pos_integer()
  def arrival_count_max, do: @arrival_count_max

  @doc "What a page shows for a stop that has no fetch yet."
  @spec waiting(String.t()) :: t()
  def waiting(stop_id) when is_binary(stop_id), do: %{stop_id: stop_id, status: :waiting}

  @doc """
  Returns the vehicles whose deviation now can move an arrival of `fetch`:
  each vehicle of an arrival that holds a prediction and the vehicle's
  deviation at the fetch, once, sorted.
  """
  @spec vehicle_ids(ArrivalBatch.Records.decoded()) :: [String.t()]
  def vehicle_ids(%{arrivals: arrivals}) when is_list(arrivals) do
    vehicle_ids =
      for %{"vehicleId" => vehicle_id} = arrival <- arrivals,
          is_binary(vehicle_id),
          is_integer(arrival["vehicleScheduleDeviationSeconds"]) do
        vehicle_id
      end

    vehicle_ids |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  Returns what a page shows at `now` for `fetch`, a stop's fetch in the
  arrivals view. `vehicles` holds, by identifier, the vehicles of
  `vehicle_ids/1` that the vehicle view holds now.
  """
  @spec arrivals(%{
          fetch: ArrivalBatch.Records.decoded(),
          vehicles: %{String.t() => VehicleView.State.vehicle()},
          now: DateTime.t()
        }) :: t()
  def arrivals(%{fetch: %{id: stop_id} = fetch, vehicles: vehicles, now: %DateTime{} = now})
      when is_binary(stop_id) and is_map(vehicles) do
    now_ms = DateTime.to_unix(now, :millisecond)
    fetched_at_ms = DateTime.to_unix(fetch.fetched_at, :millisecond)

    lines =
      fetch.arrivals
      |> Enum.map(&timed(&1, vehicles))
      |> Enum.filter(fn %{time_ms: time_ms} -> time_ms >= now_ms end)
      |> Enum.sort_by(& &1.time_ms)
      |> Enum.uniq_by(& &1.key)
      |> Enum.take(@arrival_count_max)
      |> Enum.map(&line(&1, now_ms))

    %{
      stop_id: stop_id,
      status: :arrivals,
      age_minutes: div(max(now_ms - fetched_at_ms, 0), @ms_per_minute),
      arrivals: lines
    }
  end

  defp timed(arrival, vehicles) do
    {scheduled_ms, predicted_ms} = times(arrival)

    time_ms =
      case predicted_ms do
        nil -> scheduled_ms
        predicted_ms -> predicted_ms + deviation_change_ms(arrival, vehicles)
      end

    %{
      key: {arrival["tripId"], arrival["serviceDateMs"], arrival["stopSequence"]},
      time_ms: time_ms,
      predicted: predicted_ms != nil,
      route: route_name(arrival),
      headsign: headsign(arrival)
    }
  end

  # Some agencies start a headsign with the route's short name, as in
  # "578 Puyallup" on route 578, which a page shows beside the headsign.
  defp headsign(%{"routeShortName" => short_name, "tripHeadsign" => headsign})
       when is_binary(short_name) and is_binary(headsign) do
    case String.split(headsign, " ", parts: 2) do
      [^short_name, destination] ->
        case String.trim(destination) do
          "" -> headsign
          destination -> destination
        end

      _other ->
        headsign
    end
  end

  defp headsign(%{"tripHeadsign" => headsign}), do: headsign

  defp times(%{"arrivalEnabled" => true} = arrival) do
    {arrival["scheduledArrivalTimeMs"], arrival["predictedArrivalTimeMs"]}
  end

  defp times(%{"arrivalEnabled" => false} = arrival) do
    {arrival["scheduledDepartureTimeMs"], arrival["predictedDepartureTimeMs"]}
  end

  # How much later the arrival's vehicle is now than it was at the fetch,
  # and zero for an arrival whose vehicle's deviation is not known at both
  # times on the arrival's trip.
  defp deviation_change_ms(%{"vehicleScheduleDeviationSeconds" => nil}, _vehicles), do: 0

  defp deviation_change_ms(%{"vehicleScheduleDeviationSeconds" => fetched} = arrival, vehicles)
       when is_integer(fetched) do
    case Map.get(vehicles, arrival["vehicleId"]) do
      %{"activeTripId" => trip_id, "scheduleDeviationSeconds" => current}
      when is_integer(current) ->
        case trip_id == arrival["tripId"] do
          true -> (current - fetched) * @ms_per_second
          false -> 0
        end

      _other ->
        0
    end
  end

  defp route_name(%{"routeShortName" => short_name, "routeLongName" => long_name}) do
    case short_name do
      nil -> long_name
      short_name when is_binary(short_name) -> short_name
    end
  end

  defp line(%{time_ms: time_ms} = timed, now_ms) do
    %{
      route: timed.route,
      headsign: timed.headsign,
      minutes: div(time_ms - now_ms, @ms_per_minute),
      time_ms: time_ms,
      predicted: timed.predicted
    }
  end
end
