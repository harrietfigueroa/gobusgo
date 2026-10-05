defmodule GobusgoWeb.VehicleLive do
  @moduledoc """
  The page at `/vehicles`: a map of the vehicles of every agency's current
  fetch in `Gobusgo.OneBusAway.VehicleView`, over the lines of the routes the
  two route views hold, and nothing else.

  The page's address holds a vehicle filter, which `GobusgoWeb.FilterParams`
  reads and `Gobusgo.Filter` judges under the `agency` field of
  `Gobusgo.OneBusAway.VehicleFilter`: the `agency` query parameter names
  the agencies whose vehicles and route lines the map shows, and an
  address without it shows every agency's. A filter that is
  refused shows no vehicle, no line, and a notice that links to the page
  without a filter.

  Over the map's corner the page offers the filter as a form: one checkbox
  per agency of `Gobusgo.OneBusAway.AgencyView`, from
  `GobusgoWeb.AgencyOptions`, and nothing checked for every agency. A
  change of the form goes through the same contract and, when accepted,
  into the address, and the page has the browser store the filter with the
  `vehicle-filter:store` event. A refused change changes nothing. The
  browser offers its stored filter with the `vehicle-filter:restore` event,
  which the page puts into the address only when the address supplies no
  filter itself, so a filter in an address wins and is never stored. The
  reply says whether the stored filter is one to keep.

  The page draws the basemap of the configured basemap directory, read once
  when the page is mounted. A filter that names one agency fits the map's
  view to that agency's coverage; any other filter, and an agency the
  basemap does not hold, fits the whole archive. The map element
  carries only the basemap's sources and bounds, from
  `GobusgoWeb.BasemapSources`, and the browser draws it; a change of agency
  inside one archive moves the view with the `basemap:fit` event. Before any
  extraction the page says that no basemap is available, and shows nothing
  else.

  On the map the browser draws one marker per vehicle that has a position,
  from `GobusgoWeb.VehicleMarkers`. An element that shows nothing mounts the
  hook that draws them and carries the definition of every status. A
  connected page subscribes to the view before it reads, and on every
  announcement reads the fetch of each agency whose request changed and
  whose vehicles the filter keeps. It keeps the request each agency's
  markers came from, and no vehicle. The
  markers reach the browser as
  `vehicle-markers:agency` events, each holding every marker of one agency:
  all agencies when the browser sends `vehicle-markers:ready`, and
  afterwards the agencies whose fetch changed, so a vehicle that leaves an
  agency's fetch leaves the map. A change of the filter sends every agency
  again, an agency the filter no longer keeps with no marker.

  Under the markers the browser draws one line per route, from
  `GobusgoWeb.RouteLines`: every route that an agency the filter keeps
  lists in the route view and that has a path in the route path view. A second element that shows
  nothing mounts the hook that draws them. A connected page subscribes to
  both route views, and keeps the version of each line it has sent, the
  route's color and its path's fetch time, and no polyline. The lines reach
  the browser as `route-lines:routes` events, each holding the lines of some
  routes and the routes that are gone: every line when the browser sends
  `route-lines:ready`, and afterwards the lines whose version changed. A
  change of the filter sends the lines it adds and the routes it removes.
  """

  use Phoenix.LiveView

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Basemap
  alias Gobusgo.Filter
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.VehicleFilter
  alias Gobusgo.OneBusAway.VehicleView
  alias GobusgoWeb.AgencyOptions
  alias GobusgoWeb.BasemapSources
  alias GobusgoWeb.FilterParams
  alias GobusgoWeb.RouteLines
  alias GobusgoWeb.VehicleMarkers

  @pubsub Gobusgo.PubSub
  @path "/vehicles"
  @agency_field "agency"
  @route_view Gobusgo.OneBusAway.RouteView
  @route_path_view Gobusgo.OneBusAway.RoutePathView

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :ok = AgencyView.subscribe(%{view: AgencyView, pubsub: @pubsub})
      :ok = VehicleView.subscribe(%{view: VehicleView, pubsub: @pubsub})
      :ok = FetchView.subscribe(%{view: @route_view, pubsub: @pubsub})
      :ok = FetchView.subscribe(%{view: @route_path_view, pubsub: @pubsub})
    end

    {:ok,
     assign(socket,
       manifest: read_manifest(),
       basemap: nil,
       filter: nil,
       filter_supplied: false,
       agencies: agencies(),
       shown_request_ids: %{},
       shown_route_versions: %{}
     )}
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    %{manifest: manifest, basemap: shown, filter: shown_filter} = socket.assigns
    raw = FilterParams.raw(%{params: params, spec: filter_spec()})
    filter = filter(raw)

    basemap =
      case manifest do
        nil -> nil
        manifest -> BasemapSources.view(manifest, fit_agency_id(filter))
      end

    {:noreply,
     socket
     |> assign(basemap: basemap, filter: filter, filter_supplied: raw != %{})
     |> push_fit(shown, basemap)
     |> push_filter_change(shown_filter)}
  end

  @impl Phoenix.LiveView
  def handle_info({:agency_view_switched, AgencyView}, socket) do
    {:noreply, assign(socket, agencies: agencies())}
  end

  def handle_info(
        {:vehicle_view_switched, VehicleView},
        %{assigns: %{shown_request_ids: shown_request_ids}} = socket
      ) do
    request_ids = VehicleView.current_request_ids(VehicleView)
    {:noreply, push_agencies(socket, changed_agency_ids(shown_request_ids, request_ids))}
  end

  def handle_info({:fetch_view_switched, view}, socket)
      when view in [@route_view, @route_path_view] do
    {:noreply, push_route_changes(socket)}
  end

  @impl Phoenix.LiveView
  def handle_event("route-lines:ready", _params, socket) do
    {:noreply, socket |> assign(shown_route_versions: %{}) |> push_route_changes()}
  end

  def handle_event("vehicle-filter:change", params, socket) do
    raw = FilterParams.raw(%{params: params, spec: filter_spec()})

    case filter(raw) do
      :refused ->
        {:noreply, socket}

      filter ->
        {:noreply,
         socket
         |> push_event("vehicle-filter:store", %{filter: filter})
         |> push_patch(to: path(filter))}
    end
  end

  def handle_event("vehicle-filter:restore", params, socket) do
    case {socket.assigns.filter_supplied, stored_filter(params)} do
      {true, _stored} -> {:reply, %{accepted: true}, socket}
      {false, :refused} -> {:reply, %{accepted: false}, socket}
      {false, filter} -> {:reply, %{accepted: true}, push_patch(socket, to: path(filter))}
    end
  end

  def handle_event("vehicle-markers:ready", _params, socket) do
    {:noreply, push_agencies(socket, every_agency_id(socket))}
  end

  @impl Phoenix.LiveView
  def render(assigns) do
    ~H"""
    <main>
      <p :if={@basemap == nil} id="no-basemap" class="p-8">No basemap yet.</p>

      <%!-- The form stands before the map's elements: hooks mount in document
      order, so the stored filter is offered before the map asks for its
      markers and lines. --%>
      <div :if={@basemap != nil} class="absolute left-2 top-2 z-10 flex flex-col items-start gap-2">
        <form
          id="vehicle-filter"
          phx-hook="VehicleFilter"
          phx-change="vehicle-filter:change"
          data-supplied={to_string(@filter_supplied)}
          class="rounded bg-white px-3 py-2 text-sm shadow"
        >
          <details>
            <summary class="cursor-pointer font-medium">Agencies</summary>
            <div class="mt-2 flex max-h-[60vh] flex-col gap-1 overflow-y-auto">
              <label
                :for={option <- agency_options(@agencies, @filter)}
                class="flex items-center gap-2"
              >
                <input
                  type="checkbox"
                  name="agency[]"
                  value={option.id}
                  checked={option.checked}
                />
                <span>{option.name}</span>
              </label>
            </div>
          </details>
        </form>

        <p :if={@filter == :refused} id="filter-refused" class="rounded bg-white px-3 py-2 shadow">
          This filter is not valid.
          <.link patch="/vehicles" class="underline">Remove the filter</.link>
        </p>
      </div>

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

  # The filter a raw filter stands for, or `:refused` for one the contract
  # does not accept.
  defp filter(raw) do
    case Filter.normalize(%{raw: raw, spec: filter_spec()}) do
      {:ok, filter} -> filter
      {:error, [_violation | _rest]} -> :refused
    end
  end

  # The page filters by agency alone, so any other field of the vehicle
  # filter is no parameter of its address and is refused in a stored filter.
  defp filter_spec, do: Map.take(VehicleFilter.spec(), [@agency_field])

  # What the browser stored is a filter as the page sent it, and is judged
  # again as a raw filter, since a browser can hold anything.
  defp stored_filter(%{"filter" => raw}) when is_map(raw), do: filter(raw)
  defp stored_filter(_params), do: :refused

  defp path(filter) do
    case FilterParams.query(filter) do
      "" -> @path
      query -> @path <> "?" <> query
    end
  end

  defp agencies do
    case AgencyView.current(AgencyView) do
      nil ->
        []

      %{agency_ids: agency_ids, agencies: agencies} ->
        for agency_id <- agency_ids do
          %{"id" => id, "name" => name} = Map.fetch!(agencies, agency_id)
          %{id: id, name: name}
        end
    end
  end

  defp agency_options(agencies, filter) do
    selected_ids =
      case filter do
        :refused -> []
        filter -> Map.get(filter, @agency_field, [])
      end

    AgencyOptions.options(%{agencies: agencies, selected_ids: selected_ids})
  end

  defp fit_agency_id(%{@agency_field => [agency_id]}), do: agency_id
  defp fit_agency_id(_filter), do: nil

  defp keeps_agency?(:refused, _agency_id), do: false

  defp keeps_agency?(filter, agency_id) do
    VehicleFilter.keeps_agency?(%{filter: filter, agency_id: agency_id})
  end

  # Until the map asks, the page takes it to show what the first filter of
  # the address keeps, which is what a map shows whose page connects again.
  # Another filter after that sends every agency's markers again, and the
  # lines that differ.
  defp push_filter_change(socket, nil), do: assume_shown(socket)

  defp push_filter_change(%{assigns: %{filter: filter}} = socket, shown_filter) do
    if filter == shown_filter do
      socket
    else
      socket |> push_agencies(every_agency_id(socket)) |> push_route_changes()
    end
  end

  defp assume_shown(%{assigns: %{filter: filter}} = socket) do
    request_ids =
      for {agency_id, request_id} <- VehicleView.current_request_ids(VehicleView),
          keeps_agency?(filter, agency_id),
          into: %{} do
        {agency_id, request_id}
      end

    assign(socket, shown_request_ids: request_ids, shown_route_versions: route_versions(filter))
  end

  # Every agency that has a fetch, then every agency the map shows.
  defp every_agency_id(%{assigns: %{shown_request_ids: shown_request_ids}}) do
    request_ids = VehicleView.current_request_ids(VehicleView)
    request_ids |> Map.merge(shown_request_ids) |> Map.keys() |> Enum.sort()
  end

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

  # Sends the markers of each agency's current fetch that the filter keeps,
  # and no markers for an agency the map shows that has no fetch or that
  # the filter leaves out. The fetch is read here and kept nowhere: the page
  # remembers only the request each agency's markers came from, and nothing
  # of an agency it shows no markers of.
  defp push_agencies(%{assigns: %{filter: filter}} = socket, agency_ids) do
    Enum.reduce(agency_ids, socket, fn agency_id, socket ->
      if keeps_agency?(filter, agency_id) do
        push_agency(socket, agency_id, VehicleView.current_fetch(VehicleView, agency_id))
      else
        clear_agency(socket, agency_id)
      end
    end)
  end

  defp push_agency(socket, agency_id, nil), do: clear_agency(socket, agency_id)

  defp push_agency(socket, agency_id, %{agency_id: fetch_agency_id} = fetch) do
    Assert.condition(
      fetch_agency_id == agency_id,
      "fetch must be of agency #{inspect(agency_id)}, got: #{inspect(fetch_agency_id)}"
    )

    kept = VehicleFilter.filter_fetch(%{filter: socket.assigns.filter, fetch: fetch})

    socket
    |> push_markers(VehicleMarkers.agency_markers(kept))
    |> update(:shown_request_ids, &Map.put(&1, agency_id, kept.request_id))
  end

  defp clear_agency(%{assigns: %{shown_request_ids: shown_request_ids}} = socket, agency_id) do
    if is_map_key(shown_request_ids, agency_id) do
      socket
      |> push_markers(%{agency_id: agency_id, markers: []})
      |> update(:shown_request_ids, &Map.delete(&1, agency_id))
    else
      socket
    end
  end

  defp push_markers(socket, %{agency_id: agency_id, markers: markers}) do
    push_event(socket, "vehicle-markers:agency", %{agency_id: agency_id, markers: markers})
  end

  # The version of every line to draw: the routes of each agency the
  # filter keeps, an agency's routes being one fetch of the route view.
  defp route_versions(filter) do
    route_fetches =
      for %{id: agency_id} = fetch <- FetchView.current(@route_view),
          keeps_agency?(filter, agency_id) do
        fetch
      end

    RouteLines.versions(%{
      route_fetches: route_fetches,
      path_fetch_times: FetchView.fetch_times(@route_path_view)
    })
  end

  defp push_route_changes(%{assigns: %{filter: filter, shown_route_versions: shown}} = socket) do
    versions = route_versions(filter)
    push_route_lines(socket, versions, RouteLines.changes(shown, versions))
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
