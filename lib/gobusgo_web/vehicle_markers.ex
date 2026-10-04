defmodule GobusgoWeb.VehicleMarkers do
  @report_age_ms_max 120_000
  @ms_per_second 1_000
  @ms_per_minute 60_000
  @seconds_per_minute 60
  @minutes_per_hour 60

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
  One vehicle on the map. `location_age` and `real_time` are the texts a
  page shows for the age of the last report and for whether the source has
  real-time data for the vehicle's trip.
  """
  @type marker :: %{
          id: String.t(),
          vehicle_id: String.t(),
          lat: number(),
          lon: number(),
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
  vehicle order, and the count of its vehicles that have no position. Raises
  `Gobusgo.Assert.AssertionError` when the fetch names a vehicle it does not
  hold.
  """
  @spec agency_markers(State.fetch()) :: t()
  def agency_markers(%{agency_id: agency_id, fetched_at: %DateTime{} = fetched_at} = fetch)
      when is_binary(agency_id) do
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
          fetched_at_ms: fetched_at_ms
        })
      end

    markers = Enum.reject(placed, &is_nil/1)
    position_missing_count = length(placed) - length(markers)
    Assert.condition(position_missing_count >= 0, "markers must come from the fetch's vehicles")

    %{agency_id: agency_id, markers: markers, position_missing_count: position_missing_count}
  end

  defp marker(%{"position" => nil}, _context), do: nil

  defp marker(%{"id" => vehicle_id, "position" => %{"lat" => lat, "lon" => lon}} = vehicle, %{
         agency_id: agency_id,
         fetched_at_ms: fetched_at_ms
       }) do
    report = report(vehicle["lastLocationUpdateTimeMs"], fetched_at_ms)

    %{
      id: agency_id <> "/" <> vehicle_id,
      vehicle_id: vehicle_id,
      lat: lat,
      lon: lon,
      status: status(report),
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

  defp yes_no(nil), do: @not_supplied
  defp yes_no(true), do: "Yes"
  defp yes_no(false), do: "No"
end
