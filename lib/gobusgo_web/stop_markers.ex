defmodule GobusgoWeb.StopMarkers do
  @event_stop_count_max 500

  @moduledoc """
  What a map page draws for stops: one marker per stop that a route the
  page draws serves, from the stops of the stop view. Everything here is
  pure.

  A marker holds the stop's `id`, its position as `lat` and `lon`, its
  `name`, its `code` and `direction`, each `nil` when the source supplies
  none, and `routes`, the names of the routes that serve it.

  A stop is drawn when one of its routes is drawn, so a filter that hides a
  route's line hides the stops only that route serves, and a stop no route
  serves, such as a parent station, is never drawn.

  The stops of a page go out in events of at most #{@event_stop_count_max}
  stops each.
  """

  alias Gobusgo.OneBusAway.StopView

  @type marker :: %{
          id: String.t(),
          lat: number(),
          lon: number(),
          name: String.t(),
          code: String.t() | nil,
          direction: String.t() | nil,
          routes: [String.t()]
        }

  @typedoc "The name a page shows for each route that has one, by route identifier."
  @type route_names :: %{String.t() => String.t()}

  @doc "The most stops one event holds."
  @spec event_stop_count_max() :: pos_integer()
  def event_stop_count_max, do: @event_stop_count_max

  @doc """
  Returns the name of every route of `route_fetches`, the current fetches
  of the route view, that has one: its short name, or its long name when it
  has no short name.
  """
  @spec route_names([map()]) :: route_names()
  def route_names(route_fetches) when is_list(route_fetches) do
    for %{routes: routes} <- route_fetches,
        {route_id, route} <- routes,
        name = route["shortName"] || route["longName"],
        is_binary(name),
        into: %{} do
      {route_id, name}
    end
  end

  @doc """
  Whether a page that draws the routes of `route_ids` draws `held_stop`, a
  stop of the stop view: whether one of the stop's routes is among them.
  """
  @spec drawn?(%{held_stop: StopView.State.held_stop(), route_ids: MapSet.t(String.t())}) ::
          boolean()
  def drawn?(%{held_stop: %{stop: %{"routeIds" => stop_route_ids}}, route_ids: route_ids})
      when is_list(stop_route_ids) do
    Enum.any?(stop_route_ids, &MapSet.member?(route_ids, &1))
  end

  @doc """
  Returns the marker of `held_stop`, a stop of the stop view, with the name
  in `route_names` of each of its routes that has one, in the stop's order
  of routes.
  """
  @spec marker(%{held_stop: StopView.State.held_stop(), route_names: route_names()}) :: marker()
  def marker(%{held_stop: %{id: id, stop: stop}, route_names: route_names})
      when is_binary(id) and is_map(route_names) do
    %{"lat" => lat, "lon" => lon, "name" => name, "routeIds" => route_ids} = stop

    %{
      id: id,
      lat: lat,
      lon: lon,
      name: name,
      code: stop["code"],
      direction: stop["direction"],
      routes:
        for(route_id <- route_ids, is_map_key(route_names, route_id), do: route_names[route_id])
    }
  end

  @doc "Splits `markers` into the lists that go out as one event each."
  @spec chunks([marker()]) :: [[marker()]]
  def chunks(markers) when is_list(markers), do: Enum.chunk_every(markers, @event_stop_count_max)
end
