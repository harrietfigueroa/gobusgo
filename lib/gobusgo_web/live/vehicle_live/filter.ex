defmodule GobusgoWeb.VehicleLive.Filter do
  @moduledoc """
  The filter of a vehicle page: a vehicle filter the contract accepts, or
  `:refused` for one it does not, which keeps no agency and selects nothing.

  A filter comes from a page's address, from what a browser stored, or from
  a change of the page's form. A change that names agencies keeps only the
  routes one of those agencies lists, and no route field when it lists none
  of them.

  It is pure: what the route view holds reaches it as an argument.
  """

  alias Gobusgo.Filter
  alias Gobusgo.OneBusAway.VehicleFilter
  alias GobusgoWeb.FilterParams

  @agency_field "agency"
  @route_field "route"

  @type t :: Filter.t() | :refused

  @doc "The raw filter that `params`, decoded query or form parameters, hold."
  @spec raw(map()) :: Filter.raw()
  def raw(params) when is_map(params) do
    FilterParams.raw(%{params: params, spec: VehicleFilter.spec()})
  end

  @doc "The filter `raw` stands for."
  @spec normalize(Filter.raw()) :: t()
  def normalize(raw) when is_map(raw) do
    case VehicleFilter.normalize(raw) do
      {:ok, filter} -> filter
      {:error, [_violation | _rest]} -> :refused
    end
  end

  @doc """
  The filter a browser stored, from the parameters it offers it with.
  Parameters that hold no filter are refused.
  """
  @spec stored(map()) :: t()
  # A browser can hold anything, so what it stored is judged as a raw filter.
  def stored(%{"filter" => raw}) when is_map(raw), do: normalize(raw)
  def stored(params) when is_map(params), do: :refused

  @doc """
  The filter a change of the form to `raw` stands for. `route_fetches` are
  the fetches of the route view, each with the `id` of its agency and its
  `route_ids`.
  """
  @spec changed(%{raw: Filter.raw(), route_fetches: [map()]}) :: t()
  def changed(%{raw: raw, route_fetches: route_fetches})
      when is_map(raw) and is_list(route_fetches) do
    case normalize(raw) do
      :refused -> :refused
      filter -> listed_routes_filter(filter, route_fetches)
    end
  end

  @doc "The agencies `filter` names, none for a filter with no agency field."
  @spec agency_ids(t()) :: [String.t()]
  def agency_ids(:refused), do: []
  def agency_ids(filter) when is_map(filter), do: Map.get(filter, @agency_field, [])

  @doc "The routes `filter` names, none for a filter with no route field."
  @spec route_ids(t()) :: [String.t()]
  def route_ids(:refused), do: []
  def route_ids(filter) when is_map(filter), do: Map.get(filter, @route_field, [])

  @doc "The one agency `filter` names, or `nil` for a filter that names none or several."
  @spec single_agency_id(t()) :: String.t() | nil
  def single_agency_id(%{@agency_field => [agency_id]}), do: agency_id
  def single_agency_id(filter) when is_map(filter) or filter == :refused, do: nil

  @doc "Whether `filter` keeps the vehicles and the routes of the agency."
  @spec keeps_agency?(t(), String.t()) :: boolean()
  def keeps_agency?(:refused, agency_id) when is_binary(agency_id), do: false

  def keeps_agency?(filter, agency_id) when is_map(filter) and is_binary(agency_id) do
    VehicleFilter.keeps_agency?(%{filter: filter, agency_id: agency_id})
  end

  # A filter left with no route names none, since a field of a filter
  # accepts at least one value.
  defp listed_routes_filter(
         %{@agency_field => agency_ids, @route_field => route_ids} = filter,
         route_fetches
       ) do
    listed_ids =
      for %{id: agency_id, route_ids: listed_ids} <- route_fetches,
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

  defp listed_routes_filter(filter, _route_fetches), do: filter
end
