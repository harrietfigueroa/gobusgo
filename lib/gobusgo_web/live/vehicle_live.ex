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
  `GobusgoWeb.AgencyOptions`, and nothing checked for every agency. The
  form has no control for routes and holds the routes of the address's
  filter in a hidden field. A change of the form goes through the same
  contract, and one that names agencies keeps only the routes that one of
  those agencies lists in the route view, and no route field when it lists
  none of them. When accepted, the filter goes
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
  whose line appears or goes, sends every stop again after a reset. The
  page keeps no stop, only whether the browser has asked. A third element
  that shows nothing mounts the hook that draws the stops, under the
  vehicles and only when the map is zoomed in.

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
  alias Gobusgo.OneBusAway.VehicleFilter
  alias Gobusgo.OneBusAway.VehicleView
  alias Gobusgo.Usage
  alias GobusgoWeb.AgencyOptions
  alias GobusgoWeb.AppInfoPanel
  alias GobusgoWeb.BasemapSources
  alias GobusgoWeb.FilterParams
  alias Gobusgo.OneBusAway.StopView
  alias GobusgoWeb.RouteLines
  alias GobusgoWeb.StopArrivals
  alias GobusgoWeb.StopMarkers
  alias GobusgoWeb.VehicleMarkers

  @pubsub Gobusgo.PubSub
  @path "/vehicles"
  @agency_field "agency"
  @route_field "route"
  @route_view Gobusgo.OneBusAway.RouteView
  @route_path_view Gobusgo.OneBusAway.RoutePathView
  @arrival_view Gobusgo.OneBusAway.ArrivalView
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
    raw = FilterParams.raw(%{params: params, spec: VehicleFilter.spec()})
    filter = filter(raw)

    basemap =
      case manifest do
        nil -> nil
        manifest -> BasemapSources.view(manifest, fit_agency_id(filter))
      end

    record_filter(socket, filter)

    {:noreply,
     socket
     |> assign(basemap: basemap, filter: filter, filter_supplied: raw != %{})
     |> push_fit(shown, basemap)
     |> push_filter_change(shown_filter)}
  end

  @impl Phoenix.LiveView
  def handle_info({:agency_view_switched, AgencyView}, socket) do
    {:noreply, socket |> assign(agencies: agencies()) |> push_route_changes()}
  end

  def handle_info(
        {:vehicle_view_switched, VehicleView},
        %{assigns: %{shown_request_ids: shown_request_ids}} = socket
      ) do
    request_ids = VehicleView.current_request_ids(VehicleView)

    {:noreply,
     socket
     |> push_agencies(changed_agency_ids(shown_request_ids, request_ids))
     |> push_open_stops()}
  end

  def handle_info({:fetch_view_switched, @arrival_view}, socket) do
    {:noreply, push_open_stops(socket)}
  end

  def handle_info({:fetch_view_switched, view}, socket)
      when view in [@route_view, @route_path_view] do
    shown = socket.assigns.shown_route_versions
    socket = push_route_changes(socket)

    # A stop follows the lines: a route whose line appears or goes changes
    # which stops are drawn.
    if same_routes?(shown, socket.assigns.shown_route_versions) do
      {:noreply, socket}
    else
      {:noreply, push_every_stop(socket)}
    end
  end

  def handle_info({:stop_view_switched, StopView, change}, socket) do
    %{held_ids: held_ids, removed_ids: removed_ids} = change

    case socket.assigns.stops_ready do
      true -> {:noreply, push_stops(socket, %{ids: held_ids, removed: removed_ids, reset: false})}
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
    raw = FilterParams.raw(%{params: params, spec: VehicleFilter.spec()})

    case filter(raw) do
      :refused ->
        {:noreply, socket}

      filter ->
        filter = listed_routes_filter(filter)

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

  def handle_event("stop-markers:ready", _params, socket) do
    {:noreply, socket |> assign(stops_ready: true) |> push_every_stop()}
  end

  def handle_event("stop-arrivals:open", %{"stop_id" => stop_id}, socket)
      when is_binary(stop_id) do
    case open_stop(stop_id) do
      :ok ->
        # A stop opened again is sent again, whatever the page last sent.
        {:noreply,
         socket |> update(:open_stops, &Map.put(&1, stop_id, nil)) |> push_open_stop(stop_id)}

      refusal ->
        {:noreply, push_event(socket, @stop_arrivals_event, %{stop_id: stop_id, status: refusal})}
    end
  end

  def handle_event("stop-arrivals:close", %{"stop_id" => stop_id}, socket)
      when is_binary(stop_id) do
    case is_map_key(socket.assigns.open_stops, stop_id) do
      true ->
        :ok = release_stop(stop_id)
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
        <form
          id="vehicle-filter"
          phx-hook="VehicleFilter"
          phx-change="vehicle-filter:change"
          data-supplied={to_string(@filter_supplied)}
          class="rounded bg-white px-3 py-2 text-sm shadow"
        >
          <input
            :for={{field, value} <- hidden_fields(@filter)}
            type="hidden"
            name={field}
            value={value}
          />
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
      <div :if={@basemap != nil} id="stop-markers" phx-hook="StopMarkers" hidden></div>

      <div
        :if={@basemap != nil}
        id="vehicle-markers"
        phx-hook="VehicleMarkers"
        data-statuses={JSON.encode!(VehicleMarkers.statuses())}
        hidden
      >
      </div>

      <div :if={@basemap != nil} id="route-lines" phx-hook="RouteLines" hidden></div>

      <p
        :if={@basemap != nil}
        id="snap-to-location"
        phx-hook="SnapToLocation"
        phx-update="ignore"
        role="status"
        class="fixed bottom-14 left-1/2 z-10 w-max max-w-[calc(100vw-1rem)] -translate-x-1/2 rounded bg-white px-3 py-2 text-sm shadow"
        data-bounds={JSON.encode!(@basemap.archive_bounds)}
        hidden
      >
      </p>

      <AppInfoPanel.panel agencies={@agencies} />
    </main>
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
    case VehicleFilter.normalize(raw) do
      {:ok, filter} -> filter
      {:error, [_violation | _rest]} -> :refused
    end
  end

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

  # The fields of the filter the form has no control for, each with its
  # values as one parameter value.
  defp hidden_fields(%{@route_field => route_ids}),
    do: [{@route_field, FilterParams.param(route_ids)}]

  defp hidden_fields(_filter), do: []

  # A filter of the form that names agencies keeps the routes one of them
  # lists in the route view. A filter left with no route names none, since
  # a field of a filter accepts at least one value.
  defp listed_routes_filter(%{@agency_field => agency_ids, @route_field => route_ids} = filter) do
    listed_ids =
      for %{id: agency_id, route_ids: listed_ids} <- FetchView.current(@route_view),
          agency_id in agency_ids,
          route_id <- listed_ids,
          into: MapSet.new() do
        route_id
      end

    case Enum.filter(route_ids, &MapSet.member?(listed_ids, &1)) do
      [] -> Map.delete(filter, @route_field)
      kept_ids -> Map.put(filter, @route_field, kept_ids)
    end
  end

  defp listed_routes_filter(filter), do: filter

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
      socket
      |> push_agencies(every_agency_id(socket))
      |> push_route_changes()
      |> push_every_stop()
    end
  end

  defp assume_shown(%{assigns: %{filter: filter}} = socket) do
    request_ids =
      for {agency_id, request_id} <- VehicleView.current_request_ids(VehicleView),
          keeps_agency?(filter, agency_id),
          into: %{} do
        {agency_id, request_id}
      end

    assign(socket, shown_request_ids: request_ids, shown_route_versions: route_versions(socket))
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

    stop_names = stop_names(VehicleMarkers.next_stop_ids(kept))

    socket
    |> push_markers(VehicleMarkers.agency_markers(kept, stop_names))
    |> update(:shown_request_ids, &Map.put(&1, agency_id, kept.request_id))
  end

  # Registers the stop as open for this page, so the arrival source fetches
  # it: `:refused` for a stop the stop view does not hold, and `:busy` when
  # the registry has no place for it or does not answer.
  defp open_stop(stop_id) do
    case StopView.stop(StopView, stop_id) do
      nil ->
        :refused

      _held_stop ->
        case stop_registration(stop_id) do
          :ok -> :ok
          {:error, _bound_exceeded} -> :busy
          :registry_unavailable -> :busy
        end
    end
  end

  # A registry that is down or does not answer in time exits the call.
  defp stop_registration(stop_id) do
    Demand.register(Demand, DemandKey.arrivals(stop_id))
  catch
    :exit, _reason -> :registry_unavailable
  end

  # A registry that is down holds no registration to release.
  defp release_stop(stop_id) do
    Demand.release(Demand, DemandKey.arrivals(stop_id))
  catch
    :exit, _reason -> :ok
  end

  # Registers every stop the page has open, which a registry that has just
  # started does not hold. A stop the registry refuses is closed and the
  # browser told. A registry that does not answer leaves the stop open: the
  # page watches that registry, and registers the stop when it goes down.
  defp register_open_stops(%{assigns: %{open_stops: open_stops}} = socket) do
    open_stops
    |> Map.keys()
    |> Enum.sort()
    |> Enum.reduce(socket, fn stop_id, socket ->
      case stop_registration(stop_id) do
        :ok ->
          socket

        :registry_unavailable ->
          socket

        {:error, _bound_exceeded} ->
          socket
          |> update(:open_stops, &Map.delete(&1, stop_id))
          |> push_event(@stop_arrivals_event, %{stop_id: stop_id, status: :busy})
      end
    end)
  end

  defp push_open_stops(%{assigns: %{open_stops: open_stops}} = socket) do
    open_stops |> Map.keys() |> Enum.sort() |> Enum.reduce(socket, &push_open_stop(&2, &1))
  end

  # Sends what the page shows for an open stop when it differs from what the
  # page last sent for it. The page keeps a hash of that and no arrival.
  defp push_open_stop(%{assigns: %{open_stops: open_stops}} = socket, stop_id) do
    shown = stop_arrivals(stop_id)
    version = :erlang.phash2(shown)

    case open_stops do
      %{^stop_id => ^version} ->
        socket

      open_stops ->
        socket
        |> push_event(@stop_arrivals_event, shown)
        |> assign(open_stops: Map.put(open_stops, stop_id, version))
    end
  end

  defp stop_arrivals(stop_id) do
    case FetchView.current_fetch(@arrival_view, stop_id) do
      nil ->
        StopArrivals.waiting(stop_id)

      fetch ->
        vehicles =
          for vehicle_id <- StopArrivals.vehicle_ids(fetch),
              vehicle = VehicleView.vehicle(VehicleView, vehicle_id),
              into: %{} do
            {vehicle_id, vehicle}
          end

        StopArrivals.arrivals(%{fetch: fetch, vehicles: vehicles, now: DateTime.utc_now()})
    end
  end

  # The name of each of the stops that the stop view holds.
  defp stop_names(stop_ids) do
    for stop_id <- stop_ids, held_stop = StopView.stop(StopView, stop_id), into: %{} do
      {stop_id, Map.fetch!(held_stop.stop, "name")}
    end
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

  # The version of every line to draw: the routes the filter keeps of each
  # agency it keeps, an agency's routes being one fetch of the route view.
  defp route_versions(%{assigns: %{filter: filter, agencies: agencies}}) do
    route_fetches =
      for %{id: agency_id, route_ids: route_ids} = fetch <- FetchView.current(@route_view),
          keeps_agency?(filter, agency_id) do
        kept_ids =
          Enum.filter(route_ids, fn route_id ->
            VehicleFilter.keeps_route?(%{
              filter: filter,
              agency_id: agency_id,
              route_id: route_id
            })
          end)

        %{fetch | route_ids: kept_ids}
      end

    RouteLines.versions(%{
      route_fetches: route_fetches,
      path_fetch_times: FetchView.fetch_times(@route_path_view),
      agency_names: Map.new(agencies, &{&1.id, &1.name})
    })
  end

  defp push_route_changes(%{assigns: %{shown_route_versions: shown}} = socket) do
    versions = route_versions(socket)
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
        RouteLines.line(%{version: Map.fetch!(versions, route_id), path_fetch: path_fetch})
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

  defp same_routes?(shown, versions) do
    if map_size(shown) == map_size(versions) do
      Enum.all?(shown, fn {route_id, _version} -> is_map_key(versions, route_id) end)
    else
      false
    end
  end

  # Until the browser asks for the stops it has no map to draw them on.
  defp push_every_stop(%{assigns: %{stops_ready: false}} = socket), do: socket

  defp push_every_stop(socket) do
    push_stops(socket, %{ids: StopView.stop_ids(StopView), removed: [], reset: true})
  end

  # Sends the markers of the stops of `ids` that a drawn route serves, a
  # bounded count an event, with the reset and the stops that are gone in
  # the first event. A stop of `ids` that is not drawn goes out as gone,
  # which a browser that never had it passes over, and which a reset makes
  # needless. Each stop is read here and kept nowhere.
  defp push_stops(socket, %{ids: ids, removed: removed, reset: reset}) do
    route_ids = MapSet.new(Map.keys(socket.assigns.shown_route_versions))
    route_names = StopMarkers.route_names(FetchView.current(@route_view))

    {markers, undrawn} =
      Enum.reduce(ids, {[], []}, fn id, {markers, undrawn} ->
        held_stop = StopView.stop(StopView, id)

        if held_stop != nil and StopMarkers.drawn?(%{held_stop: held_stop, route_ids: route_ids}) do
          marker = StopMarkers.marker(%{held_stop: held_stop, route_names: route_names})
          {[marker | markers], undrawn}
        else
          {markers, [id | undrawn]}
        end
      end)

    removed =
      case reset do
        true -> []
        false -> Enum.sort(removed ++ undrawn)
      end

    events =
      case {StopMarkers.chunks(Enum.reverse(markers)), removed, reset} do
        {[], [], false} ->
          []

        {[], removed, reset} ->
          [%{stops: [], removed: removed, reset: reset}]

        {[first | rest], removed, reset} ->
          [%{stops: first, removed: removed, reset: reset}] ++ stops_only(rest)
      end

    Enum.reduce(events, socket, &push_event(&2, "stop-markers:stops", &1))
  end

  defp stops_only(chunks),
    do: for(stops <- chunks, do: %{stops: stops, removed: [], reset: false})
end
