defmodule GobusgoWeb.VehicleLive do
  @moduledoc """
  The page at `/vehicles`: a map of the vehicles of every agency's current
  fetch in `Gobusgo.OneBusAway.VehicleView`, over the lines of the routes the
  two route views hold, and nothing else.

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
  connected page subscribes to the view before it reads, and on every
  announcement reads the fetch of each agency whose request changed. It
  keeps the request each agency's markers came from, and no vehicle. The
  markers reach the browser as
  `vehicle-markers:agency` events, each holding every marker of one agency:
  all agencies when the browser sends `vehicle-markers:ready`, and
  afterwards the agencies whose fetch changed, so a vehicle that leaves an
  agency's fetch leaves the map.

  Under the markers the browser draws one line per route, from
  `GobusgoWeb.RouteLines`: every route an agency lists in the route view
  that has a path in the route path view. A second element that shows
  nothing mounts the hook that draws them. A connected page subscribes to
  both route views, and keeps the version of each line it has sent, the
  route's color and its path's fetch time, and no polyline. The lines reach
  the browser as `route-lines:routes` events, each holding the lines of some
  routes and the routes that are gone: every line when the browser sends
  `route-lines:ready`, and afterwards the lines whose version changed.
  """

  use Phoenix.LiveView

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Basemap
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.VehicleView
  alias GobusgoWeb.BasemapSources
  alias GobusgoWeb.RouteLines
  alias GobusgoWeb.VehicleMarkers

  @pubsub Gobusgo.PubSub
  @route_view Gobusgo.OneBusAway.RouteView
  @route_path_view Gobusgo.OneBusAway.RoutePathView

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = VehicleView.subscribe(%{view: VehicleView, pubsub: @pubsub})
      :ok = FetchView.subscribe(%{view: @route_view, pubsub: @pubsub})
      :ok = FetchView.subscribe(%{view: @route_path_view, pubsub: @pubsub})
    end

    {:ok,
     assign(socket,
       manifest: read_manifest(),
       basemap: nil,
       shown_request_ids: VehicleView.current_request_ids(VehicleView),
       shown_route_versions: route_versions()
     )}
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
  def handle_info(
        {:vehicle_view_switched, VehicleView},
        %{assigns: %{shown_request_ids: shown_request_ids}} = socket
      ) do
    request_ids = VehicleView.current_request_ids(VehicleView)
    {:noreply, push_agencies(socket, changed_agency_ids(shown_request_ids, request_ids))}
  end

  def handle_info(
        {:fetch_view_switched, view},
        %{assigns: %{shown_route_versions: shown}} = socket
      )
      when view in [@route_view, @route_path_view] do
    versions = route_versions()
    {:noreply, push_route_lines(socket, versions, RouteLines.changes(shown, versions))}
  end

  @impl Phoenix.LiveView
  def handle_event("route-lines:ready", _params, socket) do
    versions = route_versions()
    {:noreply, push_route_lines(socket, versions, RouteLines.changes(%{}, versions))}
  end

  def handle_event("vehicle-markers:ready", _params, socket) do
    agency_ids = VehicleView |> VehicleView.current_request_ids() |> Map.keys() |> Enum.sort()
    {:noreply, push_agencies(socket, agency_ids)}
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

      <div :if={@basemap != nil} id="route-lines" phx-hook="RouteLines" hidden></div>
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

  # The agencies whose markers the map does not show yet: every agency
  # whose current fetch is another request than the one shown, then every
  # agency shown that has no fetch any more.
  defp changed_agency_ids(shown_request_ids, request_ids) do
    changed =
      for {agency_id, request_id} <- request_ids,
          Map.get(shown_request_ids, agency_id) != request_id do
        agency_id
      end

    removed =
      for {agency_id, _request_id} <- shown_request_ids, not is_map_key(request_ids, agency_id) do
        agency_id
      end

    Enum.sort(changed) ++ Enum.sort(removed)
  end

  # Sends the markers of each agency's current fetch, and no markers for an
  # agency that has none. The fetch is read here and kept nowhere: the page
  # remembers only the request each agency's markers came from.
  defp push_agencies(socket, agency_ids) do
    Enum.reduce(agency_ids, socket, fn agency_id, socket ->
      case VehicleView.current_fetch(VehicleView, agency_id) do
        nil ->
          socket
          |> push_markers(%{agency_id: agency_id, markers: []})
          |> update(:shown_request_ids, &Map.delete(&1, agency_id))

        %{agency_id: fetch_agency_id, request_id: request_id} = fetch ->
          Assert.condition(
            fetch_agency_id == agency_id,
            "fetch must be of agency #{inspect(agency_id)}, got: #{inspect(fetch_agency_id)}"
          )

          socket
          |> push_markers(VehicleMarkers.agency_markers(fetch))
          |> update(:shown_request_ids, &Map.put(&1, agency_id, request_id))
      end
    end)
  end

  defp push_markers(socket, %{agency_id: agency_id, markers: markers}) do
    push_event(socket, "vehicle-markers:agency", %{agency_id: agency_id, markers: markers})
  end

  defp route_versions do
    RouteLines.versions(%{
      route_fetches: FetchView.current(@route_view),
      path_fetch_times: FetchView.fetch_times(@route_path_view)
    })
  end

  # Sends the lines of the changed routes, a bounded count an event, and the
  # routes that are gone with the first event. Each path is read here and
  # kept nowhere: the page remembers only the version of each line.
  defp push_route_lines(socket, versions, %{changed: changed, removed: removed}) do
    lines =
      for route_id <- changed,
          path_fetch = FetchView.current_fetch(@route_path_view, route_id),
          path_fetch != nil do
        {color, _fetched_at} = Map.fetch!(versions, route_id)
        RouteLines.line(%{color: color, path_fetch: path_fetch})
      end

    events =
      case {RouteLines.chunks(lines), removed} do
        {[], []} -> []
        {[], removed} -> [%{lines: [], removed: removed}]
        {[first | rest], removed} -> [%{lines: first, removed: removed}] ++ lines_only(rest)
      end

    events
    |> Enum.reduce(socket, &push_event(&2, "route-lines:routes", &1))
    |> assign(shown_route_versions: versions)
  end

  defp lines_only(chunks), do: for(lines <- chunks, do: %{lines: lines, removed: []})
end
