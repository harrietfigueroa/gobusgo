defmodule GobusgoWeb.VehicleLive.Routes do
  @moduledoc """
  The routes a vehicle page's filter keeps, whose lines and stops the
  browser draws from the route and stop tile archive, and the positions of
  their stops, which the page fits its map to.

  It reads the route view and the stop view and changes nothing.
  """

  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.OneBusAway.VehicleFilter
  alias GobusgoWeb.MapExtent
  alias GobusgoWeb.StopMarkers
  alias GobusgoWeb.VehicleLive.Filter

  @route_view Gobusgo.OneBusAway.RouteView

  @doc """
  The routes `filter` keeps, in identifier order: each route of the route
  view that an agency the filter keeps lists and that the filter keeps.
  `:every` for a filter that names nothing, which keeps every route the
  archive holds, and none for a refused filter.
  """
  @spec kept_ids(Filter.t()) :: :every | [String.t()]
  def kept_ids(filter) when filter == %{}, do: :every
  def kept_ids(:refused), do: []

  def kept_ids(filter) when is_map(filter) do
    route_ids =
      for %{id: agency_id, route_ids: route_ids} <- FetchView.current(@route_view),
          Filter.keeps_agency?(filter, agency_id),
          route_id <- route_ids,
          VehicleFilter.keeps_route?(%{filter: filter, agency_id: agency_id, route_id: route_id}),
          uniq: true,
          do: route_id

    Enum.sort(route_ids)
  end

  @doc "The position of every stop of the stop view that a route of `route_ids` serves."
  @spec stop_positions([String.t()]) :: [MapExtent.position()]
  def stop_positions(route_ids) when is_list(route_ids) do
    route_ids = MapSet.new(route_ids)

    for held_stop <- StopView.current(StopView),
        StopMarkers.drawn?(%{held_stop: held_stop, route_ids: route_ids}) do
      %{lat: Map.fetch!(held_stop.stop, "lat"), lon: Map.fetch!(held_stop.stop, "lon")}
    end
  end
end
