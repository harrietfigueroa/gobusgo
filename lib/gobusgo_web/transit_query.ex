defmodule GobusgoWeb.TransitQuery do
  @stop_count_max 100

  @moduledoc """
  What the views answer to a question about the transit data: the agencies
  and the filter bar's suggestions, the vehicles a filter keeps, a stop's
  arrivals, the service alerts of routes and stops, a route's directions and
  stops, and the routing manifest. A vehicle page and the MCP tools ask the
  same functions, so both show the same answer to the same question.

  Every function reads the views and changes nothing, and each answer
  draws on one read of the fetch it names. The `*_version/1` functions give
  the identity of the fetches an answer draws on, a term that differs
  whenever a newer fetch would change the answer.

  A stop is found by its name, which the text must hold, whatever its case,
  or by its code, which the text must equal; the stops whose name starts
  with the text come first, in name order and then identifier order, at most
  #{@stop_count_max} of them with the count of the rest.
  """

  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.OneBusAway.VehicleView
  alias Gobusgo.Routing.Snapshots
  alias GobusgoWeb.FilterBar
  alias GobusgoWeb.RouteLines
  alias GobusgoWeb.ServiceAlerts
  alias GobusgoWeb.StopArrivals
  alias GobusgoWeb.VehicleLive.AgencyMarkers
  alias GobusgoWeb.VehicleLive.Filter

  @arrival_view Gobusgo.OneBusAway.ArrivalView
  @route_view Gobusgo.OneBusAway.RouteView
  @route_path_view Gobusgo.OneBusAway.RoutePathView
  @vehicle_situation_view Gobusgo.OneBusAway.VehicleSituationView
  @arrival_situation_view Gobusgo.OneBusAway.ArrivalSituationView

  @typedoc "The request and the time of a fetch."
  @type fetch_header :: %{request_id: String.t(), fetched_at: DateTime.t()}

  @type stop_entry :: %{
          id: String.t(),
          name: String.t(),
          code: String.t() | nil,
          direction: String.t() | nil,
          lat: number(),
          lon: number()
        }

  @type found :: %{
          agencies: [FilterBar.entry()],
          routes: [FilterBar.entry()],
          rest_count: non_neg_integer(),
          stops: [stop_entry()],
          stop_rest_count: non_neg_integer(),
          fetch: fetch_header()
        }

  @type vehicles :: %{
          fetches: [%{agency_id: String.t(), fetched_at: DateTime.t(), request_id: String.t()}],
          markers: [{String.t(), GobusgoWeb.VehicleMarkers.marker()}]
        }

  @typedoc "A stop's arrivals as a page shows them, with the fetch they come from, if any."
  @type stop_answer :: %{shown: StopArrivals.t(), fetch: fetch_header() | nil}

  @typedoc "One direction of a route: its destination name and its stops, in the order the route serves them."
  @type direction :: %{id: String.t(), name: String.t() | nil, stops: [stop_entry()]}

  @typedoc "A route as the route view lists it, its directions, and the route path fetch they come from."
  @type route_answer :: %{
          route: %{String.t() => term()},
          directions: [direction()],
          fetch: fetch_header()
        }

  @doc "The most stops one `find/1` answer holds."
  @spec stop_count_max() :: pos_integer()
  def stop_count_max, do: @stop_count_max

  @doc """
  The agencies of the agency view's current fetch, in the view's order, each
  with its `id` and `name`, and none before a fetch.
  """
  @spec agencies() :: [%{id: String.t(), name: String.t()}]
  def agencies do
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

  @doc "The current fetches of the route view, which the filter bar offers routes from."
  @spec route_fetches() :: [map()]
  def route_fetches, do: FetchView.current(@route_view)

  @doc """
  The tokens and the suggestions of the filter bar for `filter`, the text
  `query`, `agencies`, and `route_fetches`, as `GobusgoWeb.FilterBar.options/1`
  gives them. A refused filter has no token.
  """
  @spec filter_bar(%{
          filter: Filter.t(),
          query: String.t(),
          agencies: [%{id: String.t(), name: String.t()}],
          route_fetches: [map()]
        }) :: %{
          tokens: [FilterBar.entry()],
          suggestions: [FilterBar.entry()],
          rest_count: non_neg_integer()
        }
  def filter_bar(%{
        filter: filter,
        query: query,
        agencies: agencies,
        route_fetches: route_fetches
      }) do
    FilterBar.options(%{
      agencies: agencies,
      route_fetches: route_fetches,
      agency_ids: Filter.agency_ids(filter),
      route_ids: Filter.route_ids(filter),
      query: query
    })
  end

  @doc """
  The agencies, routes, and stops that the text `query`, at most
  `GobusgoWeb.RouteOptions.query_length_max/0` characters, narrows to: the
  agencies and routes the filter bar suggests for it under no filter, and
  the stops of the stop view it names. `:unavailable` before the agency
  view has a fetch.
  """
  @spec find(String.t()) :: {:ok, found()} | :unavailable
  def find(query) when is_binary(query) do
    case AgencyView.current(AgencyView) do
      nil ->
        :unavailable

      %{request_id: request_id, fetched_at: fetched_at} ->
        %{suggestions: suggestions, rest_count: rest_count} =
          filter_bar(%{
            filter: %{},
            query: query,
            agencies: agencies(),
            route_fetches: route_fetches()
          })

        %{stops: stops, rest_count: stop_rest_count} = stops(query)

        found = %{
          agencies: Enum.filter(suggestions, &(&1.field == "agency")),
          routes: Enum.filter(suggestions, &(&1.field == "route")),
          rest_count: rest_count,
          stops: stops,
          stop_rest_count: stop_rest_count,
          fetch: %{request_id: request_id, fetched_at: fetched_at}
        }

        {:ok, found}
    end
  end

  @doc "The identity of the fetches `find/1` draws on."
  @spec find_version() :: term()
  def find_version do
    agency_request_id =
      case AgencyView.current(AgencyView) do
        nil -> nil
        %{request_id: request_id} -> request_id
      end

    route_request_ids =
      for %{id: id, request_id: request_id} <- route_fetches(), do: {id, request_id}

    {agency_request_id, route_request_ids, StopView.request_ids(StopView)}
  end

  @doc """
  Every marker the vehicle page shows under `filter`, each with its
  agency's identifier, in agency identifier order, and the fetch of each
  agency that has markers shown. `:unavailable` while the vehicle view
  holds no fetch.
  """
  @spec vehicles(Filter.t()) :: {:ok, vehicles()} | :unavailable
  def vehicles(filter) do
    case vehicle_version() == %{} do
      true ->
        :unavailable

      false ->
        %{events: events, shown_request_ids: request_ids} =
          AgencyMarkers.updates(%{
            filter: filter,
            agency_ids: AgencyMarkers.every_agency_id(%{}),
            shown_request_ids: %{}
          })

        fetches =
          for %{agency_id: agency_id, fetched_at_ms: fetched_at_ms} <- events do
            %{
              agency_id: agency_id,
              fetched_at: DateTime.from_unix!(fetched_at_ms, :millisecond),
              request_id: Map.fetch!(request_ids, agency_id)
            }
          end

        markers =
          for %{agency_id: agency_id, markers: markers} <- events, marker <- markers do
            {agency_id, marker}
          end

        {:ok, %{fetches: fetches, markers: markers}}
    end
  end

  @doc "The identity of the fetches `vehicles/1` draws on: each agency's current request."
  @spec vehicle_version() :: %{String.t() => String.t()}
  def vehicle_version, do: VehicleView.current_request_ids(VehicleView)

  @doc "Whether the stop view holds the stop `stop_id`."
  @spec stop_known?(String.t()) :: boolean()
  def stop_known?(stop_id) when is_binary(stop_id), do: StopView.stop(StopView, stop_id) != nil

  @doc "The name the stop view holds for the stop `stop_id`, or `:unknown` where it holds none."
  @spec stop_name(String.t()) :: {:ok, String.t()} | :unknown
  def stop_name(stop_id) when is_binary(stop_id) do
    case StopView.stop(StopView, stop_id) do
      %{stop: %{"name" => name}} when is_binary(name) -> {:ok, name}
      _absent -> :unknown
    end
  end

  @doc """
  What a page shows for the stop `stop_id` now, from the stop's fetch in the
  arrivals view and the vehicles the vehicle view holds, with that fetch.
  """
  @spec stop_answer(String.t()) :: stop_answer()
  def stop_answer(stop_id) when is_binary(stop_id) do
    case FetchView.current_fetch(@arrival_view, stop_id) do
      nil ->
        %{shown: StopArrivals.waiting(stop_id), fetch: nil}

      %{request_id: request_id, fetched_at: fetched_at} = fetch ->
        vehicles =
          for vehicle_id <- StopArrivals.vehicle_ids(fetch),
              vehicle = VehicleView.vehicle(VehicleView, vehicle_id),
              into: %{} do
            {vehicle_id, vehicle}
          end

        shown =
          StopArrivals.arrivals(%{
            fetch: fetch,
            vehicles: vehicles,
            route_colors: route_colors(fetch),
            now: DateTime.utc_now()
          })

        %{shown: shown, fetch: %{request_id: request_id, fetched_at: fetched_at}}
    end
  end

  @doc "What a page shows for the stop `stop_id` now."
  @spec stop_arrivals(String.t()) :: StopArrivals.t()
  def stop_arrivals(stop_id) when is_binary(stop_id) do
    %{shown: shown} = stop_answer(stop_id)
    shown
  end

  @doc "The identity of the fetches `stop_answer/1` draws on."
  @spec arrivals_version(String.t()) :: term()
  def arrivals_version(stop_id) when is_binary(stop_id) do
    {FetchView.request_id(@arrival_view, stop_id), vehicle_version()}
  end

  @doc """
  The current and upcoming alerts that affect a route of `route_ids` or a
  stop of `stop_ids`, as `GobusgoWeb.ServiceAlerts.matching/1` reads them
  from the fetches of the two situation views, with the oldest of those
  fetches, which every alert is at least as fresh as. `:unavailable` while
  neither situation view holds a fetch.
  """
  @spec alerts(%{route_ids: [String.t()], stop_ids: [String.t()]}) ::
          {:ok, %{fetch: fetch_header(), alerts: [map()]}} | :unavailable
  def alerts(%{route_ids: route_ids, stop_ids: stop_ids}) do
    situation_fetches =
      FetchView.current(@vehicle_situation_view) ++ FetchView.current(@arrival_situation_view)

    case situation_fetches do
      [] ->
        :unavailable

      situation_fetches ->
        %{request_id: request_id, fetched_at: fetched_at} =
          Enum.min_by(situation_fetches, & &1.fetched_at, DateTime)

        alerts =
          ServiceAlerts.matching(%{
            situation_fetches: situation_fetches,
            route_ids: route_ids,
            stop_ids: stop_ids,
            now: DateTime.utc_now()
          })

        {:ok, %{fetch: %{request_id: request_id, fetched_at: fetched_at}, alerts: alerts}}
    end
  end

  @doc "The identity of the fetches `alerts/1` draws on: the request of each situation fetch."
  @spec alerts_version() :: {[String.t()], [String.t()]}
  def alerts_version do
    {request_ids(@vehicle_situation_view), request_ids(@arrival_situation_view)}
  end

  @doc """
  The route `route_id` as the route view lists it, with the directions of
  its route path in the order the path holds them, each stop in the order
  the route serves it. A stop the stop view does not hold is left out of its
  direction. `:unknown` for a route no fetch of the route view lists, and
  `:unavailable` while the route view holds no fetch or the path view holds
  none of this route.
  """
  @spec route(String.t()) :: {:ok, route_answer()} | :unknown | :unavailable
  def route(route_id) when is_binary(route_id) do
    fetches = route_fetches()
    listed = for %{routes: routes} <- fetches, route = routes[route_id], do: route

    case {fetches, listed} do
      {[], _listed} ->
        :unavailable

      {_fetches, []} ->
        :unknown

      {_fetches, [route | _rest]} ->
        path_fetch = FetchView.current_fetch(@route_path_view, route_id)
        route_answer(%{route: route, path_fetch: path_fetch})
    end
  end

  @doc "The identity of the fetches `route/1` draws on."
  @spec route_version(String.t()) :: term()
  def route_version(route_id) when is_binary(route_id) do
    route_request_ids =
      for %{id: id, request_id: request_id} <- route_fetches(), do: {id, request_id}

    {route_request_ids, FetchView.request_id(@route_path_view, route_id),
     StopView.request_ids(StopView)}
  end

  @doc "The body of `GET /api/routing/manifest`: the canonical JSON of the manifest."
  @spec routing_manifest() :: binary()
  def routing_manifest, do: Gobusgo.CanonicalJson.encode(Snapshots.manifest(Snapshots))

  # The CSS color of each route the route view holds for the agencies of
  # the routes `fetch` names. OneBusAway names a route by its agency's
  # identifier, an underscore, and the agency's own identifier for it.
  # https://developer.onebusaway.org/api/where/elements/agency-and-id — checked 2026-11-09
  defp route_colors(%{arrivals: arrivals}) do
    agency_ids =
      for %{"routeId" => route_id} <- arrivals, is_binary(route_id), uniq: true do
        route_id |> String.split("_", parts: 2) |> hd()
      end

    for agency_id <- agency_ids,
        %{routes: routes} <- [FetchView.current_fetch(@route_view, agency_id)],
        {route_id, route} <- routes,
        into: %{} do
      {route_id, RouteLines.css_color(route["color"])}
    end
  end

  defp route_answer(%{path_fetch: nil}), do: :unavailable

  defp route_answer(%{route: route, path_fetch: path_fetch}) do
    %{request_id: request_id, fetched_at: fetched_at, stop_groupings: stop_groupings} = path_fetch

    directions =
      for %{"type" => "direction", "stopGroups" => stop_groups} <- stop_groupings,
          %{"id" => id, "name" => name, "stopIds" => stop_ids} <- stop_groups do
        stops =
          for stop_id <- stop_ids, %{stop: stop} <- [StopView.stop(StopView, stop_id)] do
            stop_entry(stop)
          end

        %{id: id, name: name, stops: stops}
      end

    {:ok,
     %{
       route: route,
       directions: directions,
       fetch: %{request_id: request_id, fetched_at: fetched_at}
     }}
  end

  defp request_ids(view) do
    for %{request_id: request_id} <- FetchView.current(view), do: request_id
  end

  defp stops(query) do
    text = query |> String.trim() |> String.downcase()

    case text do
      "" ->
        %{stops: [], rest_count: 0}

      text ->
        ranked =
          for %{stop: %{"id" => id, "name" => name} = stop} <- StopView.current(StopView),
              rank = stop_rank(%{name: String.downcase(name), code: stop["code"], text: text}),
              rank != nil do
            {{rank, name, id}, stop_entry(stop)}
          end

        sorted = ranked |> Enum.sort_by(fn {order, _entry} -> order end) |> Enum.map(&elem(&1, 1))
        kept = Enum.take(sorted, @stop_count_max)
        %{stops: kept, rest_count: length(sorted) - length(kept)}
    end
  end

  # A stop whose name starts with the text ranks first, a stop whose name
  # holds it or whose code equals it second, and any other stop has no rank.
  defp stop_rank(%{name: name, code: code, text: text}) do
    cond do
      String.starts_with?(name, text) -> 0
      String.contains?(name, text) -> 1
      is_binary(code) and String.downcase(code) == text -> 1
      true -> nil
    end
  end

  defp stop_entry(%{"id" => id, "name" => name, "lat" => lat, "lon" => lon} = stop) do
    %{id: id, name: name, code: stop["code"], direction: stop["direction"], lat: lat, lon: lon}
  end
end
