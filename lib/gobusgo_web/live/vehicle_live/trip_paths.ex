defmodule GobusgoWeb.VehicleLive.TripPaths do
  @moduledoc """
  What a vehicle page reads from the browser's request for trip paths, and
  what it sends back, as `Gobusgo.OneBusAway.TripPaths` serves them. It is
  pure.

  A request carries at most `trip_count_max/0` trips, each with its
  `trip_id` and `route_id` as non-empty text and its `service_date_ms` as
  an integer, the start of the trip's service day in milliseconds since the
  Unix epoch. The answer sends each path with its trip, route, and service
  date beside its encoded `points` and `stops`, and each trip with no path
  with its `reason` as text.
  """

  alias Gobusgo.OneBusAway.TripPaths

  @doc "The most trips one request carries."
  @spec trip_count_max() :: pos_integer()
  def trip_count_max, do: TripPaths.request_count_max()

  @doc """
  The trips `params` ask for, as the browser sends them, or `:refused` for
  parameters that hold no list of one to `trip_count_max/0` valid trips.
  """
  @spec request(map()) :: [TripPaths.request()] | :refused
  def request(%{"trips" => trips}) when is_list(trips) do
    trip_count = length(trips)
    counted = trip_count > 0 and trip_count <= trip_count_max()

    case counted do
      true -> read_trips(trips)
      false -> :refused
    end
  end

  def request(params) when is_map(params), do: :refused

  defp read_trips(trips) do
    requests = Enum.map(trips, &read_trip/1)

    case Enum.member?(requests, :refused) do
      true -> :refused
      false -> requests
    end
  end

  defp read_trip(%{
         "trip_id" => trip_id,
         "route_id" => route_id,
         "service_date_ms" => service_date_ms
       })
       when is_binary(trip_id) and trip_id != "" and is_binary(route_id) and route_id != "" and
              is_integer(service_date_ms) do
    %{trip_id: trip_id, route_id: route_id, service_date_ms: service_date_ms}
  end

  defp read_trip(_trip), do: :refused

  @doc "The event that sends `served` to the browser."
  @spec event(%{paths: [TripPaths.path()], missing: [TripPaths.missing()]}) :: map()
  def event(%{paths: paths, missing: missing}) do
    %{paths: paths, missing: Enum.map(missing, &%{&1 | reason: Atom.to_string(&1.reason)})}
  end

  @doc """
  The event that tells the browser its request was not served, with the
  reason as text: `busy`, `killed`, or `timeout` as
  `Gobusgo.OneBusAway.TripPaths.fetch/2` answers, or `failed` for a
  request that crashed. The browser asks again for the trips it still
  needs.
  """
  @spec failed_event(TripPaths.error() | :failed) :: map()
  def failed_event(reason) when reason in [:busy, :killed, :timeout, :failed] do
    %{paths: [], missing: [], failed: Atom.to_string(reason)}
  end
end
