defmodule GobusgoWeb.VehicleLive.Lines do
  @moduledoc """
  The route lines a vehicle page sends, a bounded count an event, and the
  version of each line, which is all a page keeps of them.

  It reads the two route views and changes nothing.
  """

  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.VehicleFilter
  alias GobusgoWeb.AgencyOptions
  alias GobusgoWeb.RouteLines
  alias GobusgoWeb.VehicleLive.Filter

  @route_view Gobusgo.OneBusAway.RouteView
  @route_path_view Gobusgo.OneBusAway.RoutePathView

  @typedoc "The lines of some routes, and the routes whose line is gone."
  @type event :: %{lines: [RouteLines.line()], removed: [String.t()]}

  @doc """
  The version of every line to draw: the routes `filter` keeps of each
  agency it keeps, with the name `agencies` gives each agency.
  """
  @spec versions(%{filter: Filter.t(), agencies: [AgencyOptions.agency()]}) ::
          RouteLines.versions()
  def versions(%{filter: filter, agencies: agencies}) when is_list(agencies) do
    # An agency's routes are one fetch of the route view.
    route_fetches =
      for %{id: agency_id, route_ids: route_ids} = fetch <- FetchView.current(@route_view),
          Filter.keeps_agency?(filter, agency_id) do
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

  @doc """
  The events that take a browser from the lines of `shown` to the lines of
  `versions`: the lines whose version changed, and the routes that are gone
  in the first event. A changed route with no path in the route path view
  gets no line.
  """
  @spec events(%{shown: RouteLines.versions(), versions: RouteLines.versions()}) :: [event()]
  def events(%{shown: shown, versions: versions}) when is_map(shown) and is_map(versions) do
    %{changed: changed, removed: removed} = RouteLines.changes(shown, versions)

    lines =
      for route_id <- changed,
          path_fetch = FetchView.current_fetch(@route_path_view, route_id),
          path_fetch != nil do
        RouteLines.line(%{version: Map.fetch!(versions, route_id), path_fetch: path_fetch})
      end

    case {RouteLines.chunks(lines), removed} do
      {[], []} -> []
      {[], removed} -> [%{lines: [], removed: removed}]
      {[first | rest], removed} -> [%{lines: first, removed: removed}] ++ lines_only(rest)
    end
  end

  @doc "Whether `shown` and `versions` hold a line for the same routes."
  @spec same_routes?(%{shown: RouteLines.versions(), versions: RouteLines.versions()}) ::
          boolean()
  def same_routes?(%{shown: shown, versions: versions}) when is_map(shown) and is_map(versions) do
    if map_size(shown) == map_size(versions) do
      Enum.all?(shown, fn {route_id, _version} -> is_map_key(versions, route_id) end)
    else
      false
    end
  end

  defp lines_only(chunks), do: for(lines <- chunks, do: %{lines: lines, removed: []})
end
