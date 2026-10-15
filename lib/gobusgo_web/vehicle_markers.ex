defmodule GobusgoWeb.VehicleMarkers do
  @report_age_ms_max 120_000
  @ms_per_second 1_000
  @ms_per_minute 60_000
  @seconds_per_minute 60
  @minutes_per_hour 60
  @degrees_per_turn 360

  # The source gives an orientation as an angle in degrees where 0 is east
  # and 90 is north, so north is this many degrees.
  # https://developer.onebusaway.org/api/where/elements/trip-status — checked 2026-10-04
  @north_orientation_degrees 90

  @moduledoc """
  The markers a map page draws for the vehicles of one agency's fetch, and
  the statuses that say how far to trust each marker. Everything here is
  pure, so the markers are a function of the fetch alone.

  A marker stands at the source's estimated position, `position`, and never
  at the last reported location. The source extrapolates that position or
  takes it from the schedule when it has no fresh report, so each marker
  carries a status:

    * `:reported` — the vehicle reported a location at most
      #{div(@report_age_ms_max, @ms_per_minute)} minutes before the fetch.
    * `:stale` — the vehicle's last report is older than that.
    * `:scheduled` — the vehicle has never reported a location; its report
      time is the source's `0`.
    * `:unknown` — the source supplied no report time.

  The age of a report is the fetch time minus the report time, so a fetch's
  markers stay the same however long the fetch is shown. A vehicle with no
  position has no marker and is counted.

  A marker's heading is the way the source says the vehicle is heading at
  that position, from `orientation`, in whole degrees clockwise from north:
  `0` is north and `90` is east. An orientation of `0` is east like any
  other angle. A vehicle with no orientation supplied has no heading. The
  last reported orientation is never read, because it goes with the last
  reported location and no marker stands there.

  A marker's route is the name `route_name/1` gives its vehicle, and its
  headsign is the destination the vehicle's trip shows to riders. Either is
  `nil` when the vehicle has none.

  A marker's schedule says how far the vehicle is from its trip's schedule,
  in whole minutes, a deviation under one minute either way reading as on
  time. A `:scheduled` marker has none, because the source gives a vehicle
  that has never reported a deviation that no report backs. A marker's next
  stop names the stop the vehicle reaches next and the whole minutes to it
  as of the fetch: the name alone without a time at zero or later, the time
  alone for a stop with no name supplied. Either is `nil` when the vehicle
  has neither part.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.VehicleView.State

  @type status :: :reported | :stale | :scheduled | :unknown

  @type status_definition :: %{
          status: status(),
          label: String.t(),
          description: String.t(),
          color: String.t()
        }

  @typedoc """
  One vehicle on the map. `heading` is in degrees clockwise from north, at
  least 0 and below #{@degrees_per_turn}, or `nil` for a vehicle with no
  heading. `location_age` and `real_time` are the texts a page shows for
  the age of the last report and for whether the source has real-time data
  for the vehicle's trip, and `schedule` and `next_stop` the texts it shows
  for the vehicle's lateness and for the stop it reaches next.
  `route_id` is the route of the vehicle's trip, which the page's other
  data about the route is keyed by.
  """
  @type marker :: %{
          id: String.t(),
          vehicle_id: String.t(),
          lat: number(),
          lon: number(),
          heading: non_neg_integer() | nil,
          route_id: String.t() | nil,
          route: String.t() | nil,
          headsign: String.t() | nil,
          schedule: String.t() | nil,
          next_stop: String.t() | nil,
          status: status(),
          location_age: String.t(),
          real_time: String.t()
        }

  @type t :: %{
          agency_id: String.t(),
          markers: [marker()],
          position_missing_count: non_neg_integer()
        }

  @not_supplied "Not supplied"
  @no_location_reported "No location reported"

  @statuses [
    %{
      status: :reported,
      label: "Reported recently",
      description:
        "Location reported at most #{div(@report_age_ms_max, @ms_per_minute)} minutes before the fetch.",
      color: "#15803d"
    },
    %{
      status: :stale,
      label: "Stale",
      description:
        "Last location report is more than #{div(@report_age_ms_max, @ms_per_minute)} minutes older than the fetch.",
      color: "#b45309"
    },
    %{
      status: :scheduled,
      label: "Schedule only",
      description: "The vehicle has never reported a location.",
      color: "#6d28d9"
    },
    %{
      status: :unknown,
      label: "Report time not supplied",
      description: "The source gave no time for the last location report.",
      color: "#475569"
    }
  ]

  @doc """
  Returns the definition of every status a marker can have, in the order a
  legend lists them.
  """
  @spec statuses() :: [status_definition()]
  def statuses, do: @statuses

  @doc """
  Returns the markers of `fetch`, one agency's current fetch, in the fetch's
  vehicle order, and the count of its vehicles that have no position.
  `stop_names` gives the name of a stop by its identifier; a next stop it
  lacks is shown without a name. Raises `Gobusgo.Assert.AssertionError` when
  the fetch names a vehicle it does not hold.
  """
  @spec agency_markers(State.fetch(), %{String.t() => String.t()}) :: t()
  def agency_markers(
        %{agency_id: agency_id, fetched_at: %DateTime{} = fetched_at} = fetch,
        stop_names
      )
      when is_binary(agency_id) and is_map(stop_names) do
    %{vehicle_ids: vehicle_ids, vehicles: vehicles} = fetch
    fetched_at_ms = DateTime.to_unix(fetched_at, :millisecond)

    placed =
      for vehicle_id <- vehicle_ids do
        Assert.condition(
          is_map_key(vehicles, vehicle_id),
          "fetch must hold every vehicle it names, missing: #{inspect(vehicle_id)}"
        )

        marker(Map.fetch!(vehicles, vehicle_id), %{
          agency_id: agency_id,
          fetched_at_ms: fetched_at_ms,
          stop_names: stop_names
        })
      end

    markers = Enum.reject(placed, &is_nil/1)
    position_missing_count = length(placed) - length(markers)
    Assert.condition(position_missing_count >= 0, "markers must come from the fetch's vehicles")

    %{agency_id: agency_id, markers: markers, position_missing_count: position_missing_count}
  end

  @doc """
  Returns the identifier of every stop a vehicle of `fetch` reaches next,
  each once, sorted: the stops `agency_markers/2` looks for a name of.
  """
  @spec next_stop_ids(State.fetch()) :: [String.t()]
  def next_stop_ids(%{vehicles: vehicles}) when is_map(vehicles) do
    stop_ids = for {_id, %{"nextStopId" => stop_id}} <- vehicles, is_binary(stop_id), do: stop_id

    stop_ids |> Enum.uniq() |> Enum.sort()
  end

  @doc """
  Returns the name a page shows for the route of `vehicle`, a vehicle of a
  fetch: the route's short name, the long name of a route that has no short
  name, or `nil` for a vehicle with neither.
  """
  @spec route_name(State.vehicle()) :: String.t() | nil
  def route_name(%{"routeShortName" => short_name, "routeLongName" => long_name}) do
    case short_name do
      nil -> long_name
      short_name when is_binary(short_name) -> short_name
    end
  end

  defp marker(%{"position" => nil}, _context), do: nil

  defp marker(%{"id" => vehicle_id, "position" => %{"lat" => lat, "lon" => lon}} = vehicle, %{
         agency_id: agency_id,
         fetched_at_ms: fetched_at_ms,
         stop_names: stop_names
       }) do
    report = report(vehicle["lastLocationUpdateTimeMs"], fetched_at_ms)
    status = status(report)

    %{
      id: agency_id <> "/" <> vehicle_id,
      vehicle_id: vehicle_id,
      lat: lat,
      lon: lon,
      heading: heading(vehicle["orientation"]),
      route_id: vehicle["routeId"],
      route: route_name(vehicle),
      headsign: vehicle["tripHeadsign"],
      schedule: schedule(vehicle["scheduleDeviationSeconds"], status),
      next_stop:
        next_stop(
          Map.get(stop_names, vehicle["nextStopId"]),
          vehicle["nextStopTimeOffsetSeconds"]
        ),
      status: status,
      location_age: location_age(report),
      real_time: yes_no(vehicle["predicted"])
    }
  end

  # A report time later than the fetch time, which two clocks that disagree
  # produce, counts as a report made at the fetch time.
  defp report(nil, _fetched_at_ms), do: :not_supplied
  defp report(0, _fetched_at_ms), do: :never

  defp report(report_time_ms, fetched_at_ms) when is_integer(report_time_ms) do
    Assert.condition(report_time_ms > 0, "report time must be positive, got: #{report_time_ms}")
    {:age_ms, max(fetched_at_ms - report_time_ms, 0)}
  end

  defp heading(nil), do: nil

  defp heading(orientation) when is_number(orientation) do
    clockwise = @north_orientation_degrees - orientation
    turn_count = Float.floor(clockwise / @degrees_per_turn)

    # An angle that rounds up to a full turn is north.
    heading = rem(round(clockwise - turn_count * @degrees_per_turn), @degrees_per_turn)
    Assert.condition(heading >= 0, "heading must be at least 0, got: #{heading}")

    Assert.condition(
      heading < @degrees_per_turn,
      "heading must be below #{@degrees_per_turn}, got: #{heading}"
    )

    heading
  end

  defp status(:not_supplied), do: :unknown
  defp status(:never), do: :scheduled
  defp status({:age_ms, age_ms}) when age_ms <= @report_age_ms_max, do: :reported
  defp status({:age_ms, _age_ms}), do: :stale

  defp location_age(:not_supplied), do: @not_supplied
  defp location_age(:never), do: @no_location_reported

  defp location_age({:age_ms, age_ms}) do
    seconds = div(age_ms, @ms_per_second)
    minutes = div(seconds, @seconds_per_minute)
    hours = div(minutes, @minutes_per_hour)

    cond do
      hours > 0 -> "#{hours} h #{rem(minutes, @minutes_per_hour)} min ago"
      minutes > 0 -> "#{minutes} min #{rem(seconds, @seconds_per_minute)} s ago"
      true -> "#{seconds} s ago"
    end
  end

  defp schedule(nil, _status), do: nil
  defp schedule(_deviation_seconds, :scheduled), do: nil

  defp schedule(deviation_seconds, _status) when is_integer(deviation_seconds) do
    minutes = div(abs(deviation_seconds), @seconds_per_minute)

    cond do
      minutes == 0 -> "on time"
      deviation_seconds > 0 -> "#{minutes} min late"
      true -> "#{minutes} min early"
    end
  end

  defp next_stop(nil, offset_seconds), do: time_away(offset_seconds)

  defp next_stop(name, offset_seconds) when is_binary(name) do
    case time_away(offset_seconds) do
      nil -> name
      time_away -> name <> ", " <> time_away
    end
  end

  # An offset before zero is of a stop the vehicle has passed, which a next
  # stop is not, so it gives no time.
  defp time_away(nil), do: nil
  defp time_away(offset_seconds) when is_integer(offset_seconds) and offset_seconds < 0, do: nil

  defp time_away(offset_seconds) when is_integer(offset_seconds) do
    case div(offset_seconds, @seconds_per_minute) do
      0 -> "under 1 min away"
      minutes -> "#{minutes} min away"
    end
  end

  defp yes_no(nil), do: @not_supplied
  defp yes_no(true), do: "Yes"
  defp yes_no(false), do: "No"
end
