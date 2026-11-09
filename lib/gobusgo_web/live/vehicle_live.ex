defmodule GobusgoWeb.VehicleLive do
  @viewer_registration_retry_ms 100
  @viewer_registration_attempt_count_max 5

  @moduledoc """
  The page at `/vehicles`: a map of the vehicles of every agency's current
  fetch in `Gobusgo.OneBusAway.VehicleView`, over the lines and the stops of
  the route and stop tile archive, with the panel sheet of
  `GobusgoWeb.PanelSheet` over it. The sheet's tabs are Trip, Favorites,
  Filter, Alerts, and Settings; a page with no basemap offers Settings alone.
  Above the tabs a line names the filter the map shows. The Filter tab's badge counts the agencies and the
  routes the filter names and the Alerts tab's the current alerts, and the
  Favorites tab's badge is the browser's to write. A page with a basemap
  also gives the sheet its details view, where the browser shows the stop
  or the vehicle a rider taps on the map in place of the tabs.

  The page's address holds a vehicle filter, which `GobusgoWeb.FilterParams`
  reads and `Gobusgo.OneBusAway.VehicleFilter` judges: the `agency` query
  parameter names the agencies and the `route` query parameter the routes
  whose vehicles and route lines the map shows. The two apply together,
  and an address with neither shows every vehicle and line. A vehicle with
  no route is shown under no filter that names a route. A filter that is
  refused shows no vehicle, no line, and a notice in the line above the
  tabs that links to the page without a filter.

  The Filter tab offers the filter as one text bar, from
  `GobusgoWeb.FilterBar`: a token per agency and per route the filter
  names, and under it the suggestions that the text typed into the bar
  narrows to, the agencies of `Gobusgo.OneBusAway.AgencyView` and the
  routes of the route view, each labeled with its kind, a bounded count of
  them with the count of the rest. The page keeps the text and the
  suggestions it shows, and neither goes into the address or the stored
  filter. Choosing a suggestion adds its value to the filter and clears the
  text, and removing a token removes its value; each change goes through
  the same contract, and one that leaves agencies keeps only the routes
  that one of those agencies lists in the route view, and no route field
  when it lists none of them. When accepted and another filter than the
  page shows, it goes into the address, and the page has the browser store
  the filter with the `vehicle-filter:store` event. A refused change
  changes nothing. The
  browser offers its stored filter with the `vehicle-filter:restore` event,
  which the page puts into the address only when the address supplies no
  filter itself, so a filter in an address wins and is never stored. The
  reply says whether the stored filter is one to keep.

  The page draws the basemap of the configured basemap directory, read once
  when the page is mounted. A filter that names routes fits the map's view
  to the box around the stops of the routes it keeps, from
  `GobusgoWeb.MapExtent`, as the stop view holds them when the filter
  changes; a later fetch leaves the view where it is. A filter that names
  no route, or routes with no stop in the stop view, fits the coverage of
  the one agency it names, and any other filter, and an agency the
  basemap does not hold, fits the whole archive. The map element
  carries only the basemap's sources and bounds, from
  `GobusgoWeb.BasemapSources`, and the browser draws it; a change of the
  fitted bounds inside one archive moves the view with the `basemap:fit`
  event. Before any
  extraction the page says that no basemap is available, and shows the
  sheet with its Settings tab and nothing else.

  An element of its own mounts the hook of the location button, which
  follows the rider's location on the map. It carries the bounds of the
  whole archive and is a polite live region that starts empty; the browser
  writes into it each change of the button's state and why a follow the
  rider asked for did not happen, and a patch of the page leaves it as the
  browser has it. The rider's position stays in the browser: no event of
  this page carries it.

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

  Under the markers the browser draws the route lines and the stops of the
  current archive of `GobusgoWeb.RouteStopTiles`, and the page sends none
  of them. An element that shows nothing carries the archive's address,
  read when the page mounts and when its filter changes, and the routes the
  filter keeps, from `GobusgoWeb.VehicleLive.Routes`, which the browser
  draws the lines and the stops of: none for a refused filter, and no
  attribute for a filter that names nothing, which draws every route. A
  connected page subscribes to the route view and patches the kept routes
  as it changes. With no archive the element carries no address and the
  map draws no line and no stop. Two more elements that show nothing mount
  the hooks that draw the lines and the stops, the stops under the vehicles
  and only when the map is zoomed in.

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

  In the Favorites tab, on a page with a basemap, the page renders an empty
  panel for the rider's favorite stops, at most
  `GobusgoWeb.VehicleLive.OpenStops.favorite_count_max/0`, and leaves its
  content to the `FavoriteStop` hook: the browser keeps the favorites and
  opens their stops with `stop-arrivals:open`, as for a stop's popup, so the
  page serves the favorites' arrivals with no state of its own for them. The
  hook asks for a chosen favorite's position with `stop:position`, which the
  page answers from the stop view with the stop's `lat` and `lon`, or with
  `refused` for a stop the view does not hold.

  In the Trip tab, on a page with a basemap, the page renders an empty
  element for the trip planner, with the address of the routing manifest,
  and leaves its content to the `TripPlanner` hook, which routes in the
  browser and keeps the rider's position there. The page answers
  `trip:names`, the stops and the routes of the journeys the browser
  shows, from `GobusgoWeb.VehicleLive.Trip`, with the names the stop view
  and the route view hold. `trip:filter` names the routes of the selected
  journey: while a trip is open the page shows that filter in place of the
  rider's, with no agency, and neither puts it in the address nor has the
  browser store it; the line above the tabs names the trip's routes.
  `trip:clear` brings back the rider's filter. A change of the filter bar,
  or another filter in the address, ends the trip's filter, which the page
  tells the browser with `trip:filter-ended`; the change is stored and put
  in the address as any change is.

  In the Alerts tab the page shows the service alerts
  of the routes the filter keeps with `GobusgoWeb.ServiceAlertsPanel`, from
  `GobusgoWeb.ServiceAlerts` over the fetches of the two situation views,
  `Gobusgo.OneBusAway.VehicleSituationView` and
  `Gobusgo.OneBusAway.ArrivalSituationView`. A connected page subscribes to
  both and reads the alerts again when either switches, when the filter
  changes, and when the route view switches, which renames routes. The
  stop and vehicle views of the sheet read the current alerts of their
  routes from an element the page patches; no event carries them.
  """

  use Phoenix.LiveView

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Basemap
  alias Gobusgo.Demand
  alias Gobusgo.Gbfs.VehicleTiles
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.DemandKey
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.OneBusAway.VehicleView
  alias Gobusgo.Usage
  alias GobusgoWeb.AppInfoPanel
  alias GobusgoWeb.BasemapSources
  alias GobusgoWeb.ConnectionSignal
  alias GobusgoWeb.DonationButton
  alias GobusgoWeb.FilterBar
  alias GobusgoWeb.FilterParams
  alias GobusgoWeb.MapExtent
  alias GobusgoWeb.PanelSheet
  alias GobusgoWeb.RouteOptions
  alias GobusgoWeb.RouteStopTiles
  alias GobusgoWeb.ServiceAlerts
  alias GobusgoWeb.ServiceAlertsPanel
  alias GobusgoWeb.SharedVehicleToggle
  alias GobusgoWeb.VehicleFilterForm
  alias GobusgoWeb.VehicleLive.AgencyMarkers
  alias GobusgoWeb.VehicleLive.Filter
  alias GobusgoWeb.VehicleLive.OpenStops
  alias GobusgoWeb.VehicleLive.Routes
  alias GobusgoWeb.VehicleLive.SharedVehicles
  alias GobusgoWeb.VehicleLive.Trip
  alias GobusgoWeb.VehicleMarkers

  @pubsub Gobusgo.PubSub
  @path "/vehicles"
  @route_view Gobusgo.OneBusAway.RouteView
  @arrival_view Gobusgo.OneBusAway.ArrivalView
  @vehicle_situation_view Gobusgo.OneBusAway.VehicleSituationView
  @arrival_situation_view Gobusgo.OneBusAway.ArrivalSituationView
  @vehicle_markers_event "vehicle-markers:agency"
  @stop_arrivals_event "stop-arrivals:arrivals"
  @trip_filter_ended_event "trip:filter-ended"
  @routing_manifest_url "/api/routing/manifest"
  @shared_vehicles_hidden %{
    shown: false,
    generation: 0,
    shown_at_ms: nil,
    indexes: [],
    status: nil
  }

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      assign(socket,
        manifest: read_manifest(),
        basemap: nil,
        filter: nil,
        rider_filter: nil,
        trip: nil,
        filter_supplied: false,
        agencies: agencies(),
        filter_query: "",
        filter_bar: %{tokens: [], suggestions: [], rest_count: 0},
        shown_request_ids: %{},
        tile_archive_url: nil,
        kept_route_ids: :every,
        open_stops: %{},
        viewer_monitor: nil,
        service_alerts: %{current: [], upcoming: [], routes: %{}},
        shared_vehicles: @shared_vehicles_hidden
      )

    case connected?(socket) do
      true ->
        :ok = AgencyView.subscribe(%{view: AgencyView, pubsub: @pubsub})
        :ok = VehicleView.subscribe(%{view: VehicleView, pubsub: @pubsub})
        :ok = FetchView.subscribe(%{view: @route_view, pubsub: @pubsub})
        :ok = FetchView.subscribe(%{view: @arrival_view, pubsub: @pubsub})
        :ok = FetchView.subscribe(%{view: @vehicle_situation_view, pubsub: @pubsub})
        :ok = FetchView.subscribe(%{view: @arrival_situation_view, pubsub: @pubsub})
        {:ok, register_viewer(socket, 1)}

      false ->
        {:ok, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_params(params, _uri, socket) do
    %{manifest: manifest, basemap: shown, filter: shown_filter, rider_filter: shown_rider_filter} =
      socket.assigns

    raw = Filter.raw(params)
    rider_filter = Filter.normalize(raw)

    # Another filter in the address ends a trip's filter, as an edit does.
    socket =
      case rider_filter do
        ^shown_rider_filter -> socket
        _changed -> end_trip_filter(socket)
      end

    socket =
      socket
      |> assign(
        rider_filter: rider_filter,
        filter_supplied: raw != %{},
        tile_archive_url: tile_archive_url()
      )
      |> assign_shown_filter()

    basemap =
      case manifest do
        nil ->
          nil

        manifest ->
          manifest
          |> BasemapSources.view(Filter.single_agency_id(rider_filter))
          |> fit_routes(rider_filter)
      end

    record_filter(socket, rider_filter)

    {:noreply,
     socket
     |> assign(basemap: basemap)
     |> assign_filter_bar(FetchView.current(@route_view))
     |> assign_service_alerts()
     |> push_fit(shown, basemap)
     |> push_filter_change(shown_filter)}
  end

  @impl Phoenix.LiveView
  def handle_info({:agency_view_switched, AgencyView}, socket) do
    {:noreply,
     socket
     |> assign(agencies: agencies())
     |> assign_filter_bar(FetchView.current(@route_view))}
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

  def handle_info({:fetch_view_switched, @route_view}, socket) do
    {:noreply,
     socket
     |> assign(kept_route_ids: Routes.kept_ids(socket.assigns.filter))
     |> assign_filter_bar(FetchView.current(@route_view))
     |> assign_service_alerts()}
  end

  def handle_info({:fetch_view_switched, view}, socket)
      when view in [@vehicle_situation_view, @arrival_situation_view] do
    {:noreply, assign_service_alerts(socket)}
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

  def handle_info({:vehicle_tiles_switched, VehicleTiles}, socket) do
    {:noreply, refresh_shared_vehicles(socket)}
  end

  # A check of an earlier showing of the layer, or of a layer turned off,
  # schedules nothing more.
  def handle_info({:shared_vehicles_check, generation}, socket) do
    case socket.assigns.shared_vehicles do
      %{shown: true, generation: ^generation} ->
        schedule_shared_vehicles_check(generation)
        {:noreply, refresh_shared_vehicles(socket)}

      _other ->
        {:noreply, socket}
    end
  end

  @impl Phoenix.LiveView
  def handle_event("vehicle-filter:query", params, socket) do
    filter_query = RouteOptions.query(Map.get(params, VehicleFilterForm.query_param()))

    {:noreply,
     socket
     |> assign(filter_query: filter_query)
     |> assign_filter_bar(FetchView.current(@route_view))}
  end

  def handle_event("vehicle-filter:add", %{"field" => field, "id" => value}, socket)
      when is_binary(field) do
    route_fetches = FetchView.current(@route_view)
    change = %{filter: socket.assigns.filter, field: field, value: value}
    added = Filter.added(Map.put(change, :route_fetches, route_fetches))

    # A chosen suggestion has done what the text was typed for.
    {:noreply,
     socket
     |> assign(filter_query: "")
     |> assign_filter_bar(route_fetches)
     |> apply_filter_change(added)}
  end

  def handle_event("vehicle-filter:remove", %{"field" => field, "id" => value}, socket)
      when is_binary(field) do
    change = %{filter: socket.assigns.filter, field: field, value: value}
    removed = Filter.removed(Map.put(change, :route_fetches, FetchView.current(@route_view)))

    {:noreply, apply_filter_change(socket, removed)}
  end

  # An event whose parameters name no field is the browser's error and
  # changes nothing.
  def handle_event("vehicle-filter:" <> action, _params, socket)
      when action in ["add", "remove"] do
    {:noreply, socket}
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

  def handle_event("shared-vehicles:show", _params, socket) do
    case socket.assigns.shared_vehicles do
      %{shown: true} -> {:noreply, socket}
      %{shown: false} -> {:noreply, show_shared_vehicles(socket)}
    end
  end

  def handle_event("shared-vehicles:hide", _params, socket) do
    case socket.assigns.shared_vehicles do
      %{shown: true} -> {:noreply, hide_shared_vehicles(socket)}
      %{shown: false} -> {:noreply, socket}
    end
  end

  def handle_event("trip:names", params, socket) do
    case Trip.names_request(params) do
      :refused ->
        {:reply, %{refused: true}, socket}

      request ->
        names =
          Trip.names(%{
            request: request,
            held_stops: held_stops(request.stop_ids),
            route_fetches: FetchView.current(@route_view)
          })

        {:reply, names, socket}
    end
  end

  def handle_event("trip:filter", %{"route_ids" => route_ids}, socket) do
    case Trip.filter(route_ids) do
      :refused ->
        {:noreply, socket}

      filter ->
        {:noreply, show_trip(socket, %{filter: filter, route_ids: Enum.uniq(route_ids)})}
    end
  end

  # An event whose parameters name no routes is the browser's error and
  # changes nothing.
  def handle_event("trip:filter", _params, socket), do: {:noreply, socket}

  def handle_event("trip:clear", _params, socket), do: {:noreply, show_trip(socket, nil)}

  def handle_event("stop:position", %{"stop_id" => stop_id}, socket) when is_binary(stop_id) do
    held_stop = StopView.stop(StopView, stop_id)
    {:reply, OpenStops.position(held_stop), socket}
  end

  # A request whose parameters name no stop is the browser's error.
  def handle_event("stop:position", _params, socket), do: {:reply, %{refused: true}, socket}

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
      <ConnectionSignal.state_hook />
      <DonationButton.button class="donation-button-map" />
      <ConnectionSignal.signal :if={@basemap != nil} />

      <p :if={@basemap == nil} id="no-basemap" class="px-8 pt-16 pb-8">No basemap yet.</p>

      <%!-- The sheet stands before the map's elements: hooks mount in document
      order, so the stored filter is offered before the map asks for its
      markers and lines. --%>
      <PanelSheet.sheet detail={@basemap != nil}>
        <:summary :if={@basemap != nil}>
          <.filter_summary filter={@filter} tokens={@filter_bar.tokens} trip={@trip} />
        </:summary>

        <:tab :if={@basemap != nil} name="trip" label="Trip">
          <section
            id="trip-planner"
            phx-hook="TripPlanner"
            phx-update="ignore"
            aria-label="Plan a trip"
            data-manifest-url={routing_manifest_url()}
            data-name-count-max={Trip.name_count_max()}
            data-route-count-max={Trip.route_count_max()}
            class="trip-planner"
          >
          </section>
        </:tab>

        <:tab
          :if={@basemap != nil}
          name="favorites"
          label="Favorites"
          browser_badge_id="favorite-stop-badge"
        >
          <section
            id="favorite-stop"
            phx-hook="FavoriteStop"
            phx-update="ignore"
            aria-label="Favorite stops"
            data-favorite-count-max={OpenStops.favorite_count_max()}
            class="flex flex-col gap-2"
          >
          </section>
        </:tab>

        <:tab
          :if={@basemap != nil}
          name="filter"
          label="Filter"
          accessible_label={filter_tab_label(filter_count(@filter))}
          badge={badge_text(filter_count(@filter))}
        >
          <VehicleFilterForm.form
            tokens={@filter_bar.tokens}
            suggestions={@filter_bar.suggestions}
            rest_count={@filter_bar.rest_count}
            query={@filter_query}
            supplied={@filter_supplied}
          />
          <SharedVehicleToggle.toggle
            shown={@shared_vehicles.shown}
            status={@shared_vehicles.status}
          />
        </:tab>

        <:tab
          :if={@basemap != nil}
          name="alerts"
          label="Alerts"
          accessible_label={alerts_tab_label(length(@service_alerts.current))}
          badge={badge_text(length(@service_alerts.current))}
        >
          <ServiceAlertsPanel.content alerts={@service_alerts} />
        </:tab>

        <:tab name="settings" label="Settings">
          <AppInfoPanel.content agencies={@agencies} />
        </:tab>
      </PanelSheet.sheet>

      <.map_elements
        :if={@basemap != nil}
        basemap={@basemap}
        tile_archive_url={@tile_archive_url}
        kept_route_ids={@kept_route_ids}
        shared_vehicles={@shared_vehicles}
      />
    </main>
    """
  end

  attr :filter, :any, required: true
  attr :tokens, :list, required: true
  attr :trip, :any, required: true

  # The line that names the filter the map shows: its agencies by the agency
  # view's names, then its routes by the route view's, an agency or a route
  # a view does not hold by its identifier. A trip's filter is named as the
  # trip's routes, in the order the journey rides them.
  defp filter_summary(%{filter: :refused} = assigns) do
    ~H"""
    <p id="filter-refused">
      <.offline_prefix />This filter is not valid.
      <.link patch="/vehicles" class="underline">Remove the filter</.link>
    </p>
    """
  end

  defp filter_summary(%{trip: %{route_ids: route_ids}} = assigns) do
    names = Map.new(for %{field: "route", id: id, name: name} <- assigns.tokens, do: {id, name})
    assigns = assign(assigns, route_names: for(id <- route_ids, do: Map.get(names, id, id)))

    ~H"""
    <p id="filter-trip" class="panel-sheet-summary-line">
      <.offline_prefix />Showing the trip's routes: {Enum.join(@route_names, ", ")}
    </p>
    """
  end

  defp filter_summary(assigns) do
    assigns =
      assign(assigns,
        agency_names: for(%{field: "agency", name: name} <- assigns.tokens, do: name),
        route_names: for(%{field: "route", name: name} <- assigns.tokens, do: name)
      )

    ~H"""
    <p class="panel-sheet-summary-line">
      <.offline_prefix /><span class="text-slate-600">Showing</span>{" "}
      <span :if={@agency_names == [] and @route_names == []}>every vehicle</span>
      <%= for name <- @agency_names do %>
        <span class="panel-sheet-chip">{name}</span>{" "}
      <% end %>
      <span :if={@agency_names != [] and @route_names != []} class="text-slate-600">and</span>{" "}
      <%= for name <- @route_names do %>
        <span class="panel-sheet-chip">{name}</span>{" "}
      <% end %>
    </p>
    """
  end

  # The stylesheet shows the prefix on a phone's collapsed sheet while the
  # page is offline.
  defp offline_prefix(assigns) do
    ~H"""
    <span class="offline-prefix">{"Offline · "}</span>
    """
  end

  defp routing_manifest_url, do: @routing_manifest_url

  defp filter_count(filter),
    do: length(Filter.agency_ids(filter)) + length(Filter.route_ids(filter))

  # A count of zero shows no badge.
  defp badge_text(0), do: nil
  defp badge_text(count) when is_integer(count) and count > 0, do: Integer.to_string(count)

  defp filter_tab_label(0), do: "Filter"
  defp filter_tab_label(count), do: "Filter, #{count} applied"

  defp alerts_tab_label(0), do: "Alerts"
  defp alerts_tab_label(count), do: "Alerts, #{count} now"

  attr :basemap, :map, required: true
  attr :tile_archive_url, :string, required: true
  attr :kept_route_ids, :any, required: true
  attr :shared_vehicles, :map, required: true

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

    <div
      id="route-stop-tiles"
      phx-hook="RouteStopTiles"
      data-archive-url={@tile_archive_url}
      data-route-ids={route_ids_attribute(@kept_route_ids)}
      hidden
    >
    </div>

    <%!-- The shared vehicles' element stands before the stops' and the
    stops' before the vehicles': hooks mount in document order and add their
    layers in that order, so the vehicles are drawn over the stops and both
    over the shared vehicles. --%>
    <div
      id="shared-vehicles-layer"
      phx-hook="SharedVehicles"
      data-indexes={JSON.encode!(@shared_vehicles.indexes)}
      data-zoom-min={SharedVehicles.zoom_min()}
      data-range-low-meters={SharedVehicles.range_low_meters()}
      data-fetch-age-ms-max={SharedVehicles.fetch_age_ms_max()}
      data-form-colors={JSON.encode!(SharedVehicles.form_colors())}
      hidden
    >
    </div>

    <div
      id="stop-markers"
      phx-hook="StopMarkers"
      data-auto-open-count-max={OpenStops.auto_open_count_max()}
      hidden
    >
    </div>

    <div
      id="vehicle-markers"
      phx-hook="VehicleMarkers"
      data-statuses={JSON.encode!(VehicleMarkers.statuses())}
      hidden
    >
    </div>

    <div id="route-lines" phx-hook="RouteLines" hidden></div>

    <p
      id="follow-location"
      phx-hook="FollowLocation"
      phx-update="ignore"
      role="status"
      aria-live="polite"
      class="fixed bottom-[calc(var(--panel-sheet-inset-bottom,0px)+3.5rem)] left-1/2 z-30 w-max max-w-[calc(100vw-1rem)] -translate-x-1/2 surface px-3 py-2 text-sm shadow data-[shown=false]:pointer-events-none data-[shown=false]:opacity-0"
      data-bounds={JSON.encode!(@basemap.archive_bounds)}
      data-shown="false"
    >
    </p>
    """
  end

  # A filter that names nothing draws every route, which no list names.
  defp route_ids_attribute(:every), do: nil
  defp route_ids_attribute(route_ids) when is_list(route_ids), do: JSON.encode!(route_ids)

  # The address of the current tile archive, or `nil` while there is none.
  # A tile process that does not answer leaves the page without lines and
  # stops until it reads the address again.
  defp tile_archive_url do
    case RouteStopTiles.current_destination(RouteStopTiles) do
      nil -> nil
      destination -> "/" <> destination
    end
  catch
    :exit, reason ->
      Logger.warning("Route stop tiles not answered", reason: inspect(reason))
      nil
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
        socket
        |> assign(viewer_monitor: monitor)
        |> register_open_stops()
        |> register_shared_vehicles()

      {:error, refusal} ->
        Logger.warning("Vehicle page not counted as a viewer", refusal: refusal)

        socket
        |> assign(viewer_monitor: monitor)
        |> register_open_stops()
        |> register_shared_vehicles()

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

  # Turns the layer on: the page holds the shared vehicles key and follows
  # the indexes. A key the registry refuses or does not answer for leaves the
  # layer on, and the page holds the key again when the registry restarts.
  defp show_shared_vehicles(socket) do
    _held = SharedVehicles.hold()
    :ok = VehicleTiles.subscribe(%{server: VehicleTiles, pubsub: @pubsub})
    generation = socket.assigns.shared_vehicles.generation + 1
    schedule_shared_vehicles_check(generation)
    shown = %{shown: true, generation: generation, shown_at_ms: monotonic_ms()}

    socket
    |> assign(shared_vehicles: Map.merge(socket.assigns.shared_vehicles, shown))
    |> refresh_shared_vehicles()
  end

  defp hide_shared_vehicles(socket) do
    :ok = SharedVehicles.release()
    :ok = VehicleTiles.unsubscribe(%{server: VehicleTiles, pubsub: @pubsub})
    generation = socket.assigns.shared_vehicles.generation
    assign(socket, shared_vehicles: %{@shared_vehicles_hidden | generation: generation})
  end

  # Holds the key again for a layer that is on, with a registry that has
  # just started holding nothing.
  defp register_shared_vehicles(%{assigns: %{shared_vehicles: %{shown: true}}} = socket) do
    _held = SharedVehicles.hold()
    socket
  end

  defp register_shared_vehicles(socket), do: socket

  defp refresh_shared_vehicles(%{assigns: %{shared_vehicles: %{shown: false}}} = socket),
    do: socket

  defp refresh_shared_vehicles(socket) do
    shared_vehicles = socket.assigns.shared_vehicles
    indexes = SharedVehicles.indexes(DateTime.utc_now())
    shown_ms_ago = monotonic_ms() - shared_vehicles.shown_at_ms
    status = SharedVehicles.status(%{indexes: indexes, shown_ms_ago: shown_ms_ago})
    assign(socket, shared_vehicles: %{shared_vehicles | indexes: indexes, status: status})
  end

  defp schedule_shared_vehicles_check(generation) do
    message = {:shared_vehicles_check, generation}
    _timer = Process.send_after(self(), message, SharedVehicles.check_interval_ms())
    :ok
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

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

  # Under a filter that names routes, the view fitted to the stops of the
  # routes it keeps. A filter whose routes have no stop in the stop view
  # leaves the view as it is.
  defp fit_routes(view, filter) do
    case Filter.route_ids(filter) do
      [] ->
        view

      [_route_id | _rest] ->
        positions = Routes.stop_positions(Routes.kept_ids(filter))

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

  # A change of the filter bar that leaves another accepted filter than the
  # page shows goes into the address, and the browser stores it. It ends a
  # trip's filter, so the address's filter is the one shown after it.
  defp apply_filter_change(socket, changed) do
    shown_filter = socket.assigns.filter

    case changed do
      :refused ->
        socket

      ^shown_filter ->
        socket

      filter ->
        socket
        |> end_trip_filter()
        |> push_event("vehicle-filter:store", %{filter: filter})
        |> push_patch(to: path(filter))
    end
  end

  # Ends the trip's filter and tells the browser, whose trip stays open.
  # The filter shown is the caller's to assign.
  defp end_trip_filter(%{assigns: %{trip: nil}} = socket), do: socket

  defp end_trip_filter(socket) do
    socket |> assign(trip: nil) |> push_event(@trip_filter_ended_event, %{})
  end

  # The filter the page shows, a trip's while one is open and the rider's
  # otherwise, with the routes it keeps.
  defp assign_shown_filter(socket) do
    filter =
      case socket.assigns.trip do
        nil -> socket.assigns.rider_filter
        %{filter: trip_filter} -> trip_filter
      end

    assign(socket, filter: filter, kept_route_ids: Routes.kept_ids(filter))
  end

  # Shows `trip`, or the rider's own filter for `nil`, and sends what it
  # changes; neither the address nor the stored filter changes.
  defp show_trip(socket, trip) do
    shown_filter = socket.assigns.filter

    socket
    |> assign(trip: trip)
    |> assign_shown_filter()
    |> assign_filter_bar(FetchView.current(@route_view))
    |> assign_service_alerts()
    |> push_filter_change(shown_filter)
  end

  # The stops of `stop_ids` that the stop view holds, by identifier.
  defp held_stops(stop_ids) do
    for stop_id <- stop_ids,
        held_stop = StopView.stop(StopView, stop_id),
        held_stop != nil,
        into: %{},
        do: {stop_id, held_stop}
  end

  # The tokens and the suggestions of the page's filter, of the text in the
  # text bar, and of what the route view and the agency view hold now. A
  # refused filter has no token.
  defp assign_filter_bar(socket, route_fetches) do
    %{filter: filter, agencies: agencies, filter_query: filter_query} = socket.assigns

    assign(socket,
      filter_bar:
        FilterBar.options(%{
          agencies: agencies,
          route_fetches: route_fetches,
          agency_ids: Filter.agency_ids(filter),
          route_ids: Filter.route_ids(filter),
          query: filter_query
        })
    )
  end

  # Until the map asks, the page takes it to show what the first filter of
  # the address keeps, which is what a map shows whose page connects again.
  # Another filter after that sends every agency's markers again.
  defp push_filter_change(socket, nil), do: assume_shown(socket)

  defp push_filter_change(%{assigns: %{filter: filter}} = socket, shown_filter) do
    if filter == shown_filter do
      socket
    else
      push_every_agency(socket)
    end
  end

  defp assume_shown(%{assigns: %{filter: filter}} = socket) do
    assign(socket, shown_request_ids: AgencyMarkers.kept_request_ids(filter))
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

  defp push_events(socket, name, events) do
    Enum.reduce(events, socket, &push_event(&2, name, &1))
  end

  # The alerts of the routes the page's filter keeps, as the situation
  # views hold them now.
  defp assign_service_alerts(socket) do
    situation_fetches =
      FetchView.current(@vehicle_situation_view) ++ FetchView.current(@arrival_situation_view)

    assign(socket,
      service_alerts:
        ServiceAlerts.alerts(%{
          situation_fetches: situation_fetches,
          kept_route_ids: socket.assigns.kept_route_ids,
          route_names: ServiceAlerts.route_names(FetchView.current(@route_view)),
          now: DateTime.utc_now()
        })
    )
  end
end
