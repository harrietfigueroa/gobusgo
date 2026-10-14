defmodule GobusgoWeb.VehicleLive.Stops do
  @moduledoc """
  The stop markers a vehicle page sends, a bounded count an event: the
  stops of the stop view that a route whose line the page draws serves.

  It reads the stop view and the route view and changes nothing.
  """

  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.StopView
  alias GobusgoWeb.AgencyOptions
  alias GobusgoWeb.MapExtent
  alias GobusgoWeb.StopMarkers

  @route_view Gobusgo.OneBusAway.RouteView

  @typedoc """
  The markers of some stops, the stops that are gone, and whether the
  browser first drops every stop it has.
  """
  @type event :: %{stops: [StopMarkers.marker()], removed: [String.t()], reset: boolean()}

  @doc """
  The events for every stop of the stop view that a route of `route_ids`
  serves, after a reset. `agencies` name the agencies of the stops' routes.
  """
  @spec every(%{route_ids: MapSet.t(String.t()), agencies: [AgencyOptions.agency()]}) ::
          [event()]
  def every(%{route_ids: route_ids, agencies: agencies}) do
    events(%{
      ids: StopView.stop_ids(StopView),
      removed: [],
      reset: true,
      route_ids: route_ids,
      agencies: agencies
    })
  end

  @doc """
  The events for the stops of `ids`: the marker of each that the stop view
  holds and a route of `route_ids` serves, with `reset` and the stops that
  are gone in the first event. The stops that are gone are `removed` and
  every stop of `ids` with no marker, and none after a reset.
  """
  @spec events(%{
          ids: [String.t()],
          removed: [String.t()],
          reset: boolean(),
          route_ids: MapSet.t(String.t()),
          agencies: [AgencyOptions.agency()]
        }) :: [event()]
  def events(%{
        ids: ids,
        removed: removed,
        reset: reset,
        route_ids: route_ids,
        agencies: agencies
      })
      when is_list(ids) and is_list(removed) and is_boolean(reset) and is_list(agencies) do
    %{markers: markers, undrawn: undrawn} =
      markers(%{ids: ids, route_ids: route_ids, agencies: agencies})

    # A browser that never had a stop passes over its removal.
    removed =
      case reset do
        true -> []
        false -> Enum.sort(removed ++ undrawn)
      end

    case {StopMarkers.chunks(markers), removed, reset} do
      {[], [], false} ->
        []

      {[], removed, reset} ->
        [%{stops: [], removed: removed, reset: reset}]

      {[first | rest], removed, reset} ->
        [%{stops: first, removed: removed, reset: reset}] ++ stops_only(rest)
    end
  end

  @doc "The position of every stop of the stop view that a route of `route_ids` serves."
  @spec positions(MapSet.t(String.t())) :: [MapExtent.position()]
  def positions(route_ids) do
    for held_stop <- StopView.current(StopView),
        StopMarkers.drawn?(%{held_stop: held_stop, route_ids: route_ids}) do
      %{lat: Map.fetch!(held_stop.stop, "lat"), lon: Map.fetch!(held_stop.stop, "lon")}
    end
  end

  defp markers(%{ids: ids, route_ids: route_ids, agencies: agencies}) do
    route_fetches = FetchView.current(@route_view)
    route_names = StopMarkers.route_names(route_fetches)

    route_agency_names =
      StopMarkers.route_agency_names(%{
        route_fetches: route_fetches,
        agency_names: Map.new(agencies, &{&1.id, &1.name})
      })

    {markers, undrawn} =
      Enum.reduce(ids, {[], []}, fn id, {markers, undrawn} ->
        held_stop = StopView.stop(StopView, id)

        if held_stop != nil and StopMarkers.drawn?(%{held_stop: held_stop, route_ids: route_ids}) do
          marker =
            StopMarkers.marker(%{
              held_stop: held_stop,
              route_names: route_names,
              route_agency_names: route_agency_names
            })

          {[marker | markers], undrawn}
        else
          {markers, [id | undrawn]}
        end
      end)

    %{markers: Enum.reverse(markers), undrawn: undrawn}
  end

  defp stops_only(chunks),
    do: for(stops <- chunks, do: %{stops: stops, removed: [], reset: false})
end
