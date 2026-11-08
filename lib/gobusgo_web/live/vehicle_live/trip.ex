defmodule GobusgoWeb.VehicleLive.Trip do
  @name_count_max 128
  @route_count_max 6

  @moduledoc """
  What a vehicle page answers the browser's trip planner with. The browser
  plans a journey from the routing snapshots alone and holds the rider's
  position; the page sees only the identifiers of the stops and the routes
  of the journeys it shows, and the routes of the one selected.

  A names request carries at most #{@name_count_max} stop identifiers and
  at most #{@name_count_max} route identifiers. Its answer holds each stop
  the stop view holds, with its name and its code, and each route the route
  view holds, with the name a route shows by, its short name or else its
  long name or else its identifier, and its CSS color; an identifier a view
  does not hold is left out.

  A trip's filter names the routes of the selected journey and no agency,
  at most #{@route_count_max} of them.

  It is pure: what the views hold reaches it as arguments.
  """

  alias Gobusgo.OneBusAway.StopView.State
  alias GobusgoWeb.RouteLines
  alias GobusgoWeb.VehicleLive.Filter

  @route_field "route"

  @type names_request :: %{stop_ids: [String.t()], route_ids: [String.t()]}

  @typedoc "The answer to a names request, by identifier."
  @type names :: %{
          stops: %{String.t() => %{name: String.t() | nil, code: String.t() | nil}},
          routes: %{String.t() => %{name: String.t(), color: String.t()}}
        }

  @doc "The most stop identifiers, and the most route identifiers, one names request carries."
  @spec name_count_max() :: pos_integer()
  def name_count_max, do: @name_count_max

  @doc "The most routes a trip's filter names."
  @spec route_count_max() :: pos_integer()
  def route_count_max, do: @route_count_max

  @doc """
  The names request `params` hold, as the browser sends it, or `:refused`
  for parameters that hold no list of text identifiers within the bound.
  """
  @spec names_request(map()) :: names_request() | :refused
  def names_request(%{"stop_ids" => stop_ids, "route_ids" => route_ids}) do
    case {identifiers(stop_ids, @name_count_max), identifiers(route_ids, @name_count_max)} do
      {{:ok, stop_ids}, {:ok, route_ids}} -> %{stop_ids: stop_ids, route_ids: route_ids}
      {_stop_ids, _route_ids} -> :refused
    end
  end

  def names_request(params) when is_map(params), do: :refused

  @doc """
  The names of `request`'s stops among `held_stops`, the stop view's
  stops by identifier, and of its routes among `route_fetches`, the
  current fetches of the route view.
  """
  @spec names(%{
          request: names_request(),
          held_stops: %{String.t() => State.held_stop()},
          route_fetches: [map()]
        }) :: names()
  def names(%{request: request, held_stops: held_stops, route_fetches: route_fetches})
      when is_map(held_stops) and is_list(route_fetches) do
    stops =
      for stop_id <- request.stop_ids, Map.has_key?(held_stops, stop_id), into: %{} do
        %{stop: stop} = Map.fetch!(held_stops, stop_id)
        {stop_id, %{name: stop["name"], code: stop["code"]}}
      end

    route_ids = MapSet.new(request.route_ids)

    routes =
      for %{routes: listed} <- route_fetches,
          {route_id, route} <- listed,
          MapSet.member?(route_ids, route_id),
          into: %{} do
        name = route["shortName"] || route["longName"] || route_id
        {route_id, %{name: name, color: RouteLines.css_color(route["color"])}}
      end

    %{stops: stops, routes: routes}
  end

  @doc """
  The filter of a trip whose selected journey rides the routes
  `route_ids`, or `:refused` for identifiers the filter contract refuses, or
  none, or more than #{@route_count_max}.
  """
  @spec filter(term()) :: Filter.t()
  def filter(route_ids) do
    case identifiers(route_ids, @route_count_max) do
      {:ok, []} -> :refused
      {:ok, route_ids} -> Filter.normalize(%{@route_field => route_ids})
      :refused -> :refused
    end
  end

  # A list of at most `count_max` text identifiers, each once.
  defp identifiers(values, count_max) when is_list(values) and length(values) <= count_max do
    case Enum.all?(values, &is_binary/1) do
      true -> {:ok, Enum.uniq(values)}
      false -> :refused
    end
  end

  defp identifiers(_values, _count_max), do: :refused
end
