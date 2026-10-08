defmodule Gobusgo.OneBusAway.RouteItems do
  @agency_count_max 64
  @route_count_max 5_000

  @moduledoc """
  The route items of a set of agencies, each with the time of its latest
  fetch attempt. An item is one fetch the route source can make: the routes
  of one agency, or the stops and paths of one route.

  The routes are those the route view holds for the agencies given, so an
  agency whose routes have no fetch contributes its own item and no route.
  The attempt time of an item is what `Gobusgo.OneBusAway.FetchView.attempt_times/1`
  returns for it in its view, and `nil` for an item its view has no attempt
  of.

  A read takes at most #{@agency_count_max} agencies and
  #{@route_count_max} routes. It reads the views' tables and calls no
  process.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.FetchView

  @typedoc "One fetch the route source can make: an agency's routes, or a route's stops and paths."
  @type item :: {:routes, String.t()} | {:route_path, String.t()}

  @typedoc "An item with the time of its latest fetch attempt, `nil` when it has none."
  @type attempt :: %{item: item(), attempted_at: DateTime.t() | nil}

  @doc "The most agencies a read takes."
  @spec agency_count_max() :: pos_integer()
  def agency_count_max, do: @agency_count_max

  @doc "The most routes a read takes."
  @spec route_count_max() :: pos_integer()
  def route_count_max, do: @route_count_max

  @doc """
  Returns the items of `agency_ids`: the agencies, then the routes the
  agencies' current fetches in `route_view` list, each in identifier order
  and each once.
  """
  @spec read(%{agency_ids: [String.t()], route_view: atom(), route_path_view: atom()}) ::
          [attempt()]
  def read(%{agency_ids: agency_ids, route_view: route_view, route_path_view: route_path_view})
      when is_list(agency_ids) and is_atom(route_view) and is_atom(route_path_view) do
    agency_ids = agency_ids |> Enum.uniq() |> Enum.sort()
    agency_count = length(agency_ids)

    Assert.condition(
      agency_count <= @agency_count_max,
      "a read takes at most #{@agency_count_max} agencies, got: #{agency_count}"
    )

    route_ids = route_ids(agency_ids, route_view)
    route_count = length(route_ids)

    Assert.condition(
      route_count <= @route_count_max,
      "a read takes at most #{@route_count_max} routes, got: #{route_count}"
    )

    attempts(:routes, agency_ids, FetchView.attempt_times(route_view)) ++
      attempts(:route_path, route_ids, FetchView.attempt_times(route_path_view))
  end

  defp route_ids(agency_ids, route_view) do
    agency_ids
    |> Enum.flat_map(fn agency_id ->
      case FetchView.current_fetch(route_view, agency_id) do
        nil -> []
        %{route_ids: route_ids} -> route_ids
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp attempts(kind, ids, attempt_times) do
    for id <- ids, do: %{item: {kind, id}, attempted_at: Map.get(attempt_times, id)}
  end
end
