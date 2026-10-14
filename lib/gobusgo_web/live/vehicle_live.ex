defmodule GobusgoWeb.VehicleLive do
  @viewer_registration_retry_ms 100
  @viewer_registration_attempt_count_max 5

  @moduledoc """
  The page at `/vehicles`: a map of the vehicles of every agency's current
  fetch in `Gobusgo.OneBusAway.VehicleView`, over the lines of the routes the
  two route views hold, with the filter's controls and the info button of
  `GobusgoWeb.AppInfoPanel` over it.

  The page's address holds a vehicle filter, which `GobusgoWeb.FilterParams`
  reads and `Gobusgo.OneBusAway.VehicleFilter` judges: the `agency` query
  parameter names the agencies and the `route` query parameter the routes
  whose vehicles and route lines the map shows. The two apply together,
  and an address with neither shows every vehicle and line. A vehicle with
  no route is shown under no filter that names a route. A filter that is
  refused shows no vehicle, no line, and a notice that links to the page
  without a filter.

  Over the map's corner the page offers the filter as a form: one checkbox
  per agency of `Gobusgo.OneBusAway.AgencyView`, from
  `GobusgoWeb.AgencyOptions`, and nothing checked for every agency. Under
  them the form offers the routes, from `GobusgoWeb.RouteOptions`: one
  checkbox per route the filter names, checked, then one per route of the
  route view that the text in the form's text box narrows to, of the
  agencies the filter names or of every agency when it names none, a
  bounded count of them with the count of the rest. The page keeps the text
  and the options it shows, and neither goes into the address or the
  stored filter. A change of the form goes through the same
  contract, and one that names agencies keeps only the routes that one of
  those agencies lists in the route view, and no route field when it lists
  none of them. When accepted and another filter than the page shows, it
  goes into the address, and the page has the browser store the filter
  with the `vehicle-filter:store` event. A refused change changes nothing
  but the text. The
  browser offers its stored filter with the `vehicle-filter:restore` event,
  which the page puts into the address only when the address supplies no
  filter itself, so a filter in an address wins and is never stored. The
  reply says whether the stored filter is one to keep.

  The page draws the basemap of the configured basemap directory, read once
  when the page is mounted. A filter that names routes fits the map's view
  to the box around the stops the page draws for them, from
  `GobusgoWeb.MapExtent`, as the stop view holds them when the filter
  changes; a later fetch leaves the view where it is. A filter that names
  no route, or routes with no stop in the stop view, fits the coverage of
  the one agency it names, and any other filter, and an agency the
  basemap does not hold, fits the whole archive. The map element
  carries only the basemap's sources and bounds, from
  `GobusgoWeb.BasemapSources`, and the browser draws it; a change of the
  fitted bounds inside one archive moves the view with the `basemap:fit`
  event. Before any
  extraction the page says that no basemap is available, and shows the info
  button and nothing else.

  An element of its own mounts the hook that centers the map on the rider's
  location. It carries the bounds of the whole archive and starts hidden;
  the browser writes into it why a snap the rider asked for did not happen,
  and a patch of the page leaves it as the browser has it. The rider's
  position stays in the browser: no event of this page carries it.

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
  `GobusgoWeb.RouteLines`: every route the filter keeps that an agency the
  filter keeps lists in the route view and that has a path in the route
  path view. A second element that shows
  nothing mounts the hook that draws them. A connected page subscribes to
  both route views, and keeps the version of each line it has sent, the
  route's color, its names, and its path's fetch time, and no polyline. A
  line names its agency as the agency view does, so a switch of the agency
  view sends the lines whose agency's name changed. The lines reach
  the browser as `route-lines:routes` events, each holding the lines of some
  routes and the routes that are gone: every line when the browser sends
  `route-lines:ready`, and afterwards the lines whose version changed. A
  change of the filter sends the lines it adds and the routes it removes.

  The page sends the browser the stops of `Gobusgo.OneBusAway.StopView`
  that a route whose line it draws serves, as markers from
  `GobusgoWeb.StopMarkers`. They reach the browser as `stop-markers:stops`
  events, each holding the markers of some stops, the stops that are gone,
  and whether the browser first drops every stop it has: every stop, after
  a reset, when the browser sends `stop-markers:ready`, and afterwards the
  stops the view's announcement names. A change of the filter, and a route
  whose line appears or goes, sends every stop again after a reset, and so
  does a switch of the agency view that changes an agency's name. The
  page keeps no stop, only whether the browser has asked. A third element
  that shows nothing mounts the hook that draws the stops, under the
  vehicles and only when the map is zoomed in. A marker names the agencies
  of the stop's routes as the agency view names them.

  The browser opens a stop with the `stop-arrivals:open` event and closes
  it with `stop-arrivals:close`, each naming the stop. Opening registers
  the stop's arrivals key of `Gobusgo.OneBusAway.DemandKey` in
  `Gobusgo.Demand`, which is what has the arrival source fetch it; the page
  makes no OneBusAway request. The page answers with a
  `stop-arrivals:arrivals` event from `GobusgoWeb.StopArrivals`: `waiting`
  for a stop with no fetch in the arrivals view, `refused` for a stop the
  stop view does not hold, `busy` for a stop the registry refuses or does
  not answer for, or the stop's `arrivals`. A stop opened again is answered
  again. The page sends an open stop again when the arrivals view or the
  vehicle view switches and what it shows for the stop differs from what it
  last sent, of which it keeps a hash and no arrival.

  A connected page registers the vehicles key of
  `Gobusgo.OneBusAway.DemandKey` in `Gobusgo.Demand`, so it counts as one
  viewer of vehicles until its process exits; the static render registers
  nothing. The page monitors the registry and registers again when the
  registry it registered with goes down, so a registry that restarts counts
  the page again, and registers the stops it has open with it, closing one
  that registry refuses with a `busy` answer. While the registry does not answer, the page makes at
  most #{@viewer_registration_attempt_count_max} attempts in a row,
  #{@viewer_registration_retry_ms} ms apart. A registration
  the registry refuses, or the last of those attempts failing, leaves the
  page as it is and uncounted, and the page logs
  `Vehicle page not counted as a viewer` at `warning` with the refusal,
  `registry_unavailable` for a registry that did not answer.

  A connected page names each accepted filter it shows to the usage
  recorder, `Gobusgo.Usage`, whose record of the page's connection holds the
  last one. A refused filter is not named.
  """

  use Phoenix.LiveView

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Basemap
  alias Gobusgo.Demand
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.DemandKey
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.OneBusAway.VehicleView
  alias Gobusgo.Usage
  alias GobusgoWeb.AgencyOptions
  alias GobusgoWeb.AppInfoPanel
  alias GobusgoWeb.BasemapSources
  alias GobusgoWeb.FilterParams
  alias GobusgoWeb.MapExtent
  alias GobusgoWeb.RouteOptions
  alias GobusgoWeb.VehicleFilterForm
  alias GobusgoWeb.VehicleLive.AgencyMarkers
  alias GobusgoWeb.VehicleLive.Filter
  alias GobusgoWeb.VehicleLive.Lines
  alias GobusgoWeb.VehicleLive.OpenStops
  alias GobusgoWeb.VehicleLive.Stops
  alias GobusgoWeb.VehicleMarkers

  @pubsub Gobusgo.PubSub
  @path "/vehicles"
  @route_view Gobusgo.OneBusAway.RouteView
  @route_path_view Gobusgo.OneBusAway.RoutePathView
  @arrival_view Gobusgo.OneBusAway.ArrivalView
  @vehicle_markers_event "vehicle-markers:agency"
  @route_lines_event "route-lines:routes"
  @stop_markers_event "stop-markers:stops"
  @stop_arrivals_event "stop-arrivals:arrivals"

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        manifest: read_manifest(),
        basemap: nil,
        filter: nil,
        filter_supplied: false,
        agencies: agencies(),
        route_query: "",
        route_options: %{selected: [], matches: [], rest_count: 0},
        shown_request_ids: %{},
        shown_route_versions: %{},
        stops_ready: false,
        open_stops: %{},
        viewer_monitor: nil
      )

    case connected?(socket) do
      true ->
        :ok = AgencyView.subscribe(%{view: AgencyView, pubsub: @pubsub})
        :ok = VehicleView.subscribe(%{view: VehicleView, pubsub: @pubsub})
        :ok = FetchView.subscribe(%{view: @route_view, pubsub: @pubsub})
        :ok = FetchView.subscribe(%{view: @route_path_view, pubsub: @pubsub})
        :ok = StopView.subscribe(%{view: StopView, pubsub: @pubsub})
        :ok = FetchView.subscribe(%{view: @arrival_view, pubsub: @pubsub})
        {:ok, register_viewer(socket, 1)}

      false ->
        {:ok, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    %{manifest: manifest, basemap: shown, filter: shown_filter} = socket.assigns
    raw = Filter.raw(params)
    filter = Filter.normalize(raw)

    socket = assign(socket, filter: filter, filter_supplied: raw != %{})

    basemap =
      case manifest do
        nil ->
          nil

        manifest ->
          manifest
          |> BasemapSources.view(Filter.single_agency_id(filter))
          |> fit_routes(socket)
      end

    record_filter(socket, filter)

    {:noreply,
     socket
     |> assign(basemap: basemap)
     |> assign_route_options(FetchView.current(@route_view))
     |> push_fit(shown, basemap)
     |> push_filter_change(shown_filter)}
  end

  @impl Phoenix.LiveView
  def handle_info({:agency_view_switched, AgencyView}, socket) do
    names = agency_names(socket.assigns.agencies)

    socket =
      socket
      |> assign(agencies: agencies())
      |> assign_route_options(FetchView.current(@route_view))
      |> push_route_changes()

    # A stop's marker names the agencies of its routes, and the view
    # switches at every fetch, most of which rename no agency.
    if agency_names(socket.assigns.agencies) == names do
      {:noreply, socket}
    else
      {:noreply, push_every_stop(socket)}
    end
  end

  def handle_info(
        {:vehicle_view_switched, VehicleView},
        %{assigns: %{shown_request_ids: shown_request_ids}} = socket
      ) do
    agency_ids =
      AgencyMarkers.changed_agency_ids(%{
        shown_request_ids: shown_request_ids,
        request_ids: VehicleView.current_request_ids(VehicleView)
      })

    {:noreply, socket |> push_agencies(agency_ids) |> push_open_stops()}
  end

  def handle_info({:fetch_view_switched, @arrival_view}, socket) do
    {:noreply, push_open_stops(socket)}
  end

  def handle_info({:fetch_view_switched, view}, socket)
      when view in [@route_view, @route_path_view] do
    shown = socket.assigns.shown_route_versions
    socket = socket |> follow_route_view(view) |> push_route_changes()

    # A stop follows the lines: a route whose line appears or goes changes
    # which stops are drawn.
    if Lines.same_routes?(%{shown: shown, versions: socket.assigns.shown_route_versions}) do
      {:noreply, socket}
    else
      {:noreply, push_every_stop(socket)}
    end
  end

  def handle_info({:stop_view_switched, StopView, change}, socket) do
    %{held_ids: held_ids, removed_ids: removed_ids} = change

    case socket.assigns.stops_ready do
      true -> {:noreply, push_stops(socket, %{ids: held_ids, removed: removed_ids})}
      false -> {:noreply, socket}
    end
  end

  def handle_info(
        {:DOWN, monitor, :process, _registry, _reason},
        %{assigns: %{viewer_monitor: monitor}} = socket
      ) do
    {:noreply, register_viewer(assign(socket, viewer_monitor: nil), 1)}
  end

  def handle_info({:register_viewer, attempt_count}, socket) do
    {:noreply, register_viewer(socket, attempt_count)}
  end

  @impl Phoenix.LiveView
  def handle_event("route-lines:ready", _params, socket) do
    {:noreply, socket |> assign(shown_route_versions: %{}) |> push_route_changes()}
  end

  def handle_event("vehicle-filter:change", params, socket) do
    shown_filter = socket.assigns.filter
    route_fetches = FetchView.current(@route_view)
    route_query = RouteOptions.query(Map.get(params, VehicleFilterForm.route_query_param()))

    socket =
      socket
      |> assign(route_query: route_query)
      |> assign_route_options(route_fetches)

    case Filter.changed(%{raw: Filter.raw(params), route_fetches: route_fetches}) do
      :refused ->
        {:noreply, socket}

      # Text typed into the text box changes the form and not the filter.
      ^shown_filter ->
        {:noreply, socket}

      filter ->
        {:noreply,
         socket
         |> push_event("vehicle-filter:store", %{filter: filter})
         |> push_patch(to: path(filter))}
    end
  end

  def handle_event("vehicle-filter:restore", params, socket) do
    case {socket.assigns.filter_supplied, Filter.stored(params)} do
      {true, _stored} -> {:reply, %{accepted: true}, socket}
      {false, :refused} -> {:reply, %{accepted: false}, socket}
      {false, filter} -> {:reply, %{accepted: true}, push_patch(socket, to: path(filter))}
    end
  end

  def handle_event("vehicle-markers:ready", _params, socket) do
    {:noreply, push_every_agency(socket)}
  end

  def handle_event("stop-markers:ready", _params, socket) do
    {:noreply, socket |> assign(stops_ready: true) |> push_every_stop()}
  end

  def handle_event("stop-arrivals:open", %{"stop_id" => stop_id}, socket)
      when is_binary(stop_id) do
    case OpenStops.open(stop_id) do
      :ok ->
        # A stop opened again is sent again, whatever the page last sent.
        {:noreply,
         socket
         |> update(:open_stops, &Map.put(&1, stop_id, nil))
         |> push_open_stops([stop_id])}

      refusal ->
        {:noreply, push_event(socket, @stop_arrivals_event, %{stop_id: stop_id, status: refusal})}
    end
  end

  def handle_event("stop-arrivals:close", %{"stop_id" => stop_id}, socket)
      when is_binary(stop_id) do
    case is_map_key(socket.assigns.open_stops, stop_id) do
      true ->
        :ok = OpenStops.release(stop_id)
        {:noreply, update(socket, :open_stops, &Map.delete(&1, stop_id))}

      false ->
        {:noreply, socket}
    end
  end

  # An event whose parameters name no stop is the browser's error and
  # changes nothing.
  def handle_event("stop-arrivals:" <> action, _params, socket)
      when action in ["open", "close"] do
    {:noreply, socket}
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
        <VehicleFilterForm.form
          agency_options={agency_options(@agencies, @filter)}
          route_options={@route_options}
          route_query={@route_query}
          supplied={@filter_supplied}
        />

        <p :if={@filter == :refused} id="filter-refused" class="surface px-3 py-2 shadow">
          This filter is not valid.
          <.link patch="/vehicles" class="underline">Remove the filter</.link>
        </p>
      </div>

      <.map_elements :if={@basemap != nil} basemap={@basemap} />

      <AppInfoPanel.panel agencies={@agencies} />
    </main>
    """
  end

  attr :basemap, :map, required: true

  defp map_elements(assigns) do
    ~H"""
    <div
      id={"basemap-" <> Path.rootname(@basemap.archive)}
      phx-hook="Basemap"
      phx-update="ignore"
      class="h-screen w-full"
      data-library-url={@basemap.sources.library_url}
      data-archive-url={@basemap.sources.archive_url}
      data-fonts-url={@basemap.sources.fonts_url}
      data-sprites-url={@basemap.sources.sprites_url}
      data-attribution={@basemap.sources.attribution}
      data-bounds={JSON.encode!(@basemap.bounds)}
    >
    </div>

    <%!-- The stops' element stands before the vehicles': hooks mount in
    document order and add their layers in that order, so the vehicles are
    drawn over the stops. --%>
    <div id="stop-markers" phx-hook="StopMarkers" hidden></div>

    <div
      id="vehicle-markers"
      phx-hook="VehicleMarkers"
      data-statuses={JSON.encode!(VehicleMarkers.statuses())}
      hidden
    >
    </div>

    <div id="route-lines" phx-hook="RouteLines" hidden></div>

    <p
      id="snap-to-location"
      phx-hook="SnapToLocation"
      phx-update="ignore"
      role="status"
      class="fixed bottom-14 left-1/2 z-10 w-max max-w-[calc(100vw-1rem)] -translate-x-1/2 surface px-3 py-2 text-sm shadow"
      data-bounds={JSON.encode!(@basemap.archive_bounds)}
      hidden
    >
    </p>
    """
  end

  # Names the filter a connected page shows to the usage recorder. A refused
  # filter shows nothing and is not named.
  defp record_filter(socket, filter) do
    case {connected?(socket), filter} do
      {true, %{} = filter} -> Usage.put_filter(Usage, filter)
      {_connected, _filter} -> :ok
    end
  end

  # Makes the attempt numbered `attempt_count` of a row of attempts to
  # register the page. The page watches the registry it registers with, a
  # registry that refuses it included, so a later registry gets the page's
  # registration too.
  defp register_viewer(socket, attempt_count) do
    Assert.condition(socket.assigns.viewer_monitor == nil, "the registry must not be watched yet")
    Assert.condition(attempt_count >= 1, "attempt_count must be positive, got: #{attempt_count}")

    Assert.condition(
      attempt_count <= @viewer_registration_attempt_count_max,
      "attempt_count must be at most #{@viewer_registration_attempt_count_max}, got: #{attempt_count}"
    )

    monitor = Process.monitor(Demand)

    case viewer_registration() do
      :ok ->
        socket |> assign(viewer_monitor: monitor) |> register_open_stops()

      {:error, refusal} ->
        Logger.warning("Vehicle page not counted as a viewer", refusal: refusal)
        socket |> assign(viewer_monitor: monitor) |> register_open_stops()

      :registry_unavailable ->
        Process.demonitor(monitor, [:flush])

        if attempt_count < @viewer_registration_attempt_count_max do
          retry = {:register_viewer, attempt_count + 1}
          Process.send_after(self(), retry, @viewer_registration_retry_ms)
        else
          Logger.warning("Vehicle page not counted as a viewer", refusal: :registry_unavailable)
        end

        socket
    end
  end

  # A registry that is down or does not answer in time exits the call.
  defp viewer_registration do
    Demand.register(Demand, DemandKey.vehicles())
  catch
    :exit, _reason -> :registry_unavailable
  end

  # Registers every stop the page has open, which a registry that has just
  # started does not hold. A stop the registry refuses is closed and the
  # browser told. A registry that does not answer leaves the stop open: the
  # page watches that registry, and registers the stop when it goes down.
  defp register_open_stops(socket) do
    socket.assigns.open_stops
    |> OpenStops.register()
    |> Enum.reduce(socket, fn stop_id, socket ->
      socket
      |> update(:open_stops, &Map.delete(&1, stop_id))
      |> push_event(@stop_arrivals_event, %{stop_id: stop_id, status: :busy})
    end)
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

  # Under a filter that names routes, the view fitted to the stops the page
  # draws, the stops of the routes whose lines it draws. A filter whose
  # routes have no stop in the stop view leaves the view as it is.
  defp fit_routes(view, socket) do
    case Filter.route_ids(socket.assigns.filter) do
      [] ->
        view

      [_route_id | _rest] ->
        positions = socket |> route_versions() |> Map.keys() |> MapSet.new() |> Stops.positions()

        case MapExtent.bounds(%{positions: positions, within: view.archive_bounds}) do
          nil -> view
          bounds -> BasemapSources.fitted(view, bounds)
        end
    end
  end

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

  defp agency_names(agencies), do: Map.new(agencies, &{&1.id, &1.name})

  defp agency_options(agencies, filter) do
    AgencyOptions.options(%{agencies: agencies, selected_ids: Filter.agency_ids(filter)})
  end

  # The route options of the page's filter, of the text in the text box,
  # and of what the route view and the agency view hold now. A refused
  # filter selects nothing.
  defp assign_route_options(socket, route_fetches) do
    %{filter: filter, agencies: agencies, route_query: route_query} = socket.assigns

    assign(socket,
      route_options:
        RouteOptions.options(%{
          route_fetches: route_fetches,
          agency_names: agency_names(agencies),
          agency_ids: Filter.agency_ids(filter),
          selected_ids: Filter.route_ids(filter),
          query: route_query
        })
    )
  end

  # The route options name the routes of the route view, and nothing of a
  # route's path.
  defp follow_route_view(socket, @route_view) do
    assign_route_options(socket, FetchView.current(@route_view))
  end

  defp follow_route_view(socket, @route_path_view), do: socket

  # Until the map asks, the page takes it to show what the first filter of
  # the address keeps, which is what a map shows whose page connects again.
  # Another filter after that sends every agency's markers again, and the
  # lines that differ.
  defp push_filter_change(socket, nil), do: assume_shown(socket)

  defp push_filter_change(%{assigns: %{filter: filter}} = socket, shown_filter) do
    if filter == shown_filter do
      socket
    else
      socket
      |> push_every_agency()
      |> push_route_changes()
      |> push_every_stop()
    end
  end

  defp assume_shown(%{assigns: %{filter: filter}} = socket) do
    assign(socket,
      shown_request_ids: AgencyMarkers.kept_request_ids(filter),
      shown_route_versions: route_versions(socket)
    )
  end

  defp push_every_agency(socket) do
    push_agencies(socket, AgencyMarkers.every_agency_id(socket.assigns.shown_request_ids))
  end

  # Each fetch is read for the event and kept nowhere: the page remembers
  # only the request each agency's markers came from, and nothing of an
  # agency it shows no markers of.
  defp push_agencies(socket, agency_ids) do
    %{filter: filter, shown_request_ids: shown_request_ids} = socket.assigns

    %{events: events, shown_request_ids: shown_request_ids} =
      AgencyMarkers.updates(%{
        filter: filter,
        agency_ids: agency_ids,
        shown_request_ids: shown_request_ids
      })

    socket
    |> push_events(@vehicle_markers_event, events)
    |> assign(shown_request_ids: shown_request_ids)
  end

  defp push_open_stops(socket) do
    push_open_stops(socket, Enum.sort(Map.keys(socket.assigns.open_stops)))
  end

  # The page keeps a hash of what it sent for each stop and no arrival.
  defp push_open_stops(socket, stop_ids) do
    %{events: events, open_stops: open_stops} =
      OpenStops.updates(%{open_stops: socket.assigns.open_stops, stop_ids: stop_ids})

    socket |> push_events(@stop_arrivals_event, events) |> assign(open_stops: open_stops)
  end

  defp route_versions(%{assigns: %{filter: filter, agencies: agencies}}) do
    Lines.versions(%{filter: filter, agencies: agencies})
  end

  # Each path is read for the event and kept nowhere: the page remembers
  # only the version of each line.
  defp push_route_changes(%{assigns: %{shown_route_versions: shown}} = socket) do
    versions = route_versions(socket)

    socket
    |> push_events(@route_lines_event, Lines.events(%{shown: shown, versions: versions}))
    |> assign(shown_route_versions: versions)
  end

  # Until the browser asks for the stops it has no map to draw them on.
  defp push_every_stop(%{assigns: %{stops_ready: false}} = socket), do: socket

  defp push_every_stop(socket) do
    push_events(socket, @stop_markers_event, Stops.every(drawn_routes(socket)))
  end

  # Each stop is read for the event and kept nowhere.
  defp push_stops(socket, %{ids: ids, removed: removed}) do
    events =
      Stops.events(Map.merge(drawn_routes(socket), %{ids: ids, removed: removed, reset: false}))

    push_events(socket, @stop_markers_event, events)
  end

  defp drawn_routes(%{assigns: %{shown_route_versions: shown, agencies: agencies}}) do
    %{route_ids: MapSet.new(Map.keys(shown)), agencies: agencies}
  end

  defp push_events(socket, name, events) do
    Enum.reduce(events, socket, &push_event(&2, name, &1))
  end
end
