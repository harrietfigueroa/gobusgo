defmodule GobusgoWeb.VehicleLive do
  @moduledoc """
  The page at `/vehicles`: a test page that lists the vehicles of every
  agency's current fetch in `Gobusgo.OneBusAway.VehicleView`, by agency and
  then by vehicle, and names the fetch each agency's vehicles come from.

  The page draws on one read of the view, so each agency's vehicles all come
  from one fetch of that agency. A connected page subscribes to the view
  before it reads, and reads again on every announcement, so it shows a
  fetch that completes while it is open. Before any fetch is complete it
  says that no vehicle data is available.

  The source's position is labeled an estimate, because the source
  extrapolates it or takes it from the schedule when the vehicle has not
  reported. The last reported location and the time it was reported are
  shown beside it, apart from the time the fetch was made. A field the
  source did not supply reads "Not supplied", and a location update time of
  zero, the source's value for a vehicle that has never reported, reads "No
  location reported".
  """

  use Phoenix.LiveView

  alias Gobusgo.OneBusAway.VehicleView

  @pubsub Gobusgo.PubSub
  @not_supplied "Not supplied"
  @no_location_reported "No location reported"
  @time_out_of_range "Out of range"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = VehicleView.subscribe(%{view: VehicleView, pubsub: @pubsub})
    end

    {:ok, assign_fetches(socket)}
  end

  @impl Phoenix.LiveView
  def handle_info({:vehicle_view_switched, VehicleView}, socket) do
    {:noreply, assign_fetches(socket)}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-7xl p-8">
      <h1 class="text-2xl font-semibold">Vehicles</h1>

      <p :if={@fetches == []} id="no-data" class="mt-4">No vehicle data yet.</p>

      <div :if={@fetches != []}>
        <ul class="mt-2 text-sm text-slate-600">
          <li :for={fetch <- @fetches} id={"fetch-#{fetch.agency_id}"}>
            Agency {fetch.agency_id}: {vehicle_count(fetch.vehicle_ids)}, fetched at {iso8601(
              fetch.fetched_at
            )} by request {fetch.request_id}.
          </li>
        </ul>

        <table class="mt-4 w-full text-left text-sm">
          <thead class="border-b border-slate-300">
            <tr>
              <th class="py-2 pr-4">Vehicle</th>
              <th class="py-2 pr-4">Agency</th>
              <th class="py-2 pr-4">Trip</th>
              <th class="py-2 pr-4">Estimated position (latitude, longitude)</th>
              <th class="py-2 pr-4">Last reported location (latitude, longitude)</th>
              <th class="py-2 pr-4">Location reported at</th>
              <th class="py-2 pr-4">Real-time data</th>
              <th class="py-2">Fetched at</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={row <- @rows}
              id={"vehicle-#{row.agency_id}-#{row.vehicle["id"]}"}
              class="border-b border-slate-200"
            >
              <td data-column="vehicle" class="py-2 pr-4">{row.vehicle["id"]}</td>
              <td data-column="agency" class="py-2 pr-4">{row.agency_id}</td>
              <td data-column="trip" class="py-2 pr-4">{text(row.vehicle["activeTripId"])}</td>
              <td data-column="estimated-position" class="py-2 pr-4">
                {coordinates(row.vehicle["position"])}
              </td>
              <td data-column="reported-location" class="py-2 pr-4">
                {coordinates(row.vehicle["lastKnownLocation"])}
              </td>
              <td data-column="location-reported-at" class="py-2 pr-4">
                {location_reported_at(row.vehicle["lastLocationUpdateTimeMs"])}
              </td>
              <td data-column="real-time" class="py-2 pr-4">{yes_no(row.vehicle["predicted"])}</td>
              <td data-column="fetched-at" class="py-2">{iso8601(row.fetched_at)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </main>
    """
  end

  defp assign_fetches(socket) do
    fetches = VehicleView.current(VehicleView)

    rows =
      for %{vehicle_ids: vehicle_ids, vehicles: vehicles} = fetch <- fetches,
          vehicle_id <- vehicle_ids do
        %{
          agency_id: fetch.agency_id,
          fetched_at: fetch.fetched_at,
          vehicle: Map.fetch!(vehicles, vehicle_id)
        }
      end

    assign(socket, fetches: fetches, rows: rows)
  end

  defp iso8601(%DateTime{} = time), do: DateTime.to_iso8601(time, :extended)

  defp vehicle_count([_vehicle_id]), do: "1 vehicle"
  defp vehicle_count(vehicle_ids), do: "#{length(vehicle_ids)} vehicles"

  defp text(nil), do: @not_supplied
  defp text(value) when is_binary(value), do: value

  defp coordinates(nil), do: @not_supplied
  defp coordinates(%{"lat" => lat, "lon" => lon}), do: "#{lat}, #{lon}"

  defp yes_no(nil), do: @not_supplied
  defp yes_no(true), do: "Yes"
  defp yes_no(false), do: "No"

  defp location_reported_at(nil), do: @not_supplied
  defp location_reported_at(0), do: @no_location_reported

  defp location_reported_at(time_ms) when is_integer(time_ms) do
    case DateTime.from_unix(time_ms, :millisecond) do
      {:ok, time} -> iso8601(time)
      {:error, _reason} -> @time_out_of_range
    end
  end
end
