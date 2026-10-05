defmodule GobusgoWeb.VehicleLive do
  @moduledoc """
  The page at `/vehicles`: a map of the vehicles of every agency's current
  fetch in `Gobusgo.OneBusAway.VehicleView`, and nothing else.

  The page draws the basemap of the configured basemap directory, read once
  when the page is mounted. The `agency` query parameter chooses the agency
  whose coverage the map's view fits; without it, and for an agency the
  basemap does not hold, the view fits the whole archive. The map element
  carries only the basemap's sources and bounds, from
  `GobusgoWeb.BasemapSources`, and the browser draws it; a change of agency
  inside one archive moves the view with the `basemap:fit` event. Before any
  extraction the page says that no basemap is available, and shows nothing
  else.

  On the map the browser draws one marker per vehicle that has a position,
  from `GobusgoWeb.VehicleMarkers`. An element that shows nothing mounts the
  hook that draws them and carries the definition of every status. A
  connected page subscribes to the view before it reads, and reads again on
  every announcement. The markers reach the browser as
  `vehicle-markers:agency` events, each holding every marker of one agency:
  all agencies when the browser sends `vehicle-markers:ready`, and
  afterwards the agencies whose fetch changed, so a vehicle that leaves an
  agency's fetch leaves the map.
  """

  use Phoenix.LiveView

  require Logger

  alias Gobusgo.Basemap
  alias Gobusgo.OneBusAway.VehicleView
  alias GobusgoWeb.BasemapSources
  alias GobusgoWeb.VehicleMarkers

  @pubsub Gobusgo.PubSub

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = VehicleView.subscribe(%{view: VehicleView, pubsub: @pubsub})
    end

    {:ok, socket |> assign(manifest: read_manifest(), basemap: nil) |> assign_fetches()}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, %{assigns: %{manifest: manifest, basemap: shown}} = socket) do
    basemap =
      case manifest do
        nil -> nil
        manifest -> BasemapSources.view(manifest, params["agency"])
      end

    {:noreply, socket |> assign(basemap: basemap) |> push_fit(shown, basemap)}
  end

  @impl Phoenix.LiveView
  def handle_info({:vehicle_view_switched, VehicleView}, %{assigns: %{fetches: shown}} = socket) do
    socket = assign_fetches(socket)
    {:noreply, push_marker_sets(socket, changed_marker_sets(shown, socket.assigns.fetches))}
  end

  @impl Phoenix.LiveView
  def handle_event("vehicle-markers:ready", _params, %{assigns: %{fetches: fetches}} = socket) do
    {:noreply, push_marker_sets(socket, Enum.map(fetches, &VehicleMarkers.agency_markers/1))}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <main>
      <p :if={@basemap == nil} id="no-basemap" class="p-8">No basemap yet.</p>

      <div
        :if={@basemap != nil}
        id={"basemap-" <> Path.rootname(@basemap.archive)}
        phx-hook="Basemap"
        phx-update="ignore"
        class="h-screen w-full"
        data-archive-url={@basemap.sources.archive_url}
        data-fonts-url={@basemap.sources.fonts_url}
        data-sprites-url={@basemap.sources.sprites_url}
        data-attribution={@basemap.sources.attribution}
        data-bounds={JSON.encode!(@basemap.bounds)}
      >
      </div>

      <div
        :if={@basemap != nil}
        id="vehicle-markers"
        phx-hook="VehicleMarkers"
        data-statuses={JSON.encode!(VehicleMarkers.statuses())}
        hidden
      >
      </div>
    </main>
    """
  end

  # A directory with no manifest is the state before any extraction and
  # shows no map. A manifest that cannot be used shows no map either, and is
  # worth a look.
  defp read_manifest do
    case Basemap.read_manifest(GobusgoWeb.Endpoint.basemap_dir()) do
      {:ok, manifest} ->
        manifest

      {:error, :not_found} ->
        nil

      {:error, reason} ->
        Logger.warning("Basemap manifest not usable", reason: inspect(reason))
        nil
    end
  end

  # The map element is ignored on update, so a new view inside the archive
  # the page already shows reaches the map as an event. A change of archive
  # changes the element's id, which mounts a new map with its own bounds.
  defp push_fit(socket, %{archive: archive, bounds: shown_bounds}, %{
         archive: archive,
         bounds: bounds
       })
       when bounds != shown_bounds do
    push_event(socket, "basemap:fit", %{bounds: bounds})
  end

  defp push_fit(socket, _shown, _basemap), do: socket

  defp assign_fetches(socket), do: assign(socket, fetches: VehicleView.current(VehicleView))

  # The marker sets the map does not show yet: one for every agency whose
  # fetch is another request than the one shown, and an empty one for every
  # agency that has no fetch any more.
  defp changed_marker_sets(shown_fetches, fetches) do
    shown = Map.new(shown_fetches, &{&1.agency_id, &1.request_id})
    current_ids = MapSet.new(fetches, & &1.agency_id)

    changed =
      for %{agency_id: agency_id, request_id: request_id} = fetch <- fetches,
          Map.get(shown, agency_id) != request_id do
        VehicleMarkers.agency_markers(fetch)
      end

    removed =
      for %{agency_id: agency_id} <- shown_fetches, not MapSet.member?(current_ids, agency_id) do
        %{agency_id: agency_id, markers: []}
      end

    changed ++ removed
  end

  defp push_marker_sets(socket, marker_sets) do
    Enum.reduce(marker_sets, socket, fn %{agency_id: agency_id, markers: markers}, socket ->
      push_event(socket, "vehicle-markers:agency", %{agency_id: agency_id, markers: markers})
    end)
  end
end
