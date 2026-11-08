defmodule GobusgoWeb.FilterBar do
  @moduledoc """
  What a map page's filter bar shows: one token per value the filter names,
  and the suggestions the text a rider typed narrows to, each entry labeled
  with the field of the filter it is a value of. Everything here is pure.

  The tokens are the agencies of `GobusgoWeb.AgencyOptions` that the filter
  names, then the routes `GobusgoWeb.RouteOptions` selects, whatever the
  text, so a page can show and remove every value of its filter.

  The suggestions are none for text that is blank once trimmed. Otherwise
  they are the agencies the filter does not name whose name holds the text,
  whatever its case, those whose name starts with it first and in name
  order within that, then the matches of `GobusgoWeb.RouteOptions`, which
  are of the agencies the filter names, or of every agency when it names
  none. A page gets at most `GobusgoWeb.RouteOptions.match_count_max/0`
  suggestions and the count of the rest.
  """

  alias GobusgoWeb.AgencyOptions
  alias GobusgoWeb.RouteOptions

  @agency_field "agency"
  @route_field "route"

  @type entry :: %{
          field: String.t(),
          id: String.t(),
          name: String.t(),
          detail: String.t() | nil,
          agency_name: String.t() | nil
        }

  @doc """
  Returns the tokens and the suggestions for `agencies`, the agencies of the
  agency view, and `route_fetches`, the current fetches of the route view,
  under a filter that names the agencies `agency_ids` and the routes
  `route_ids`, narrowed by `query`, text of at most
  `GobusgoWeb.RouteOptions.query_length_max/0` characters. `rest_count` is
  the count of the suggestions left out.
  """
  @spec options(%{
          agencies: [AgencyOptions.agency()],
          route_fetches: [map()],
          agency_ids: [String.t()],
          route_ids: [String.t()],
          query: String.t()
        }) :: %{tokens: [entry()], suggestions: [entry()], rest_count: non_neg_integer()}
  def options(%{
        agencies: agencies,
        route_fetches: route_fetches,
        agency_ids: agency_ids,
        route_ids: route_ids,
        query: query
      })
      when is_list(agencies) and is_list(route_fetches) and is_list(agency_ids) and
             is_list(route_ids) and is_binary(query) do
    agency_options = AgencyOptions.options(%{agencies: agencies, selected_ids: agency_ids})
    text = query |> String.trim() |> String.downcase()

    route_options =
      RouteOptions.options(%{
        route_fetches: route_fetches,
        agency_names: Map.new(agencies, &{&1.id, &1.name}),
        agency_ids: agency_ids,
        selected_ids: route_ids,
        query: query
      })

    agency_tokens = for %{checked: true} = option <- agency_options, do: agency_entry(option)
    route_tokens = Enum.map(route_options.selected, &route_entry/1)

    suggestions =
      case text do
        "" ->
          %{suggestions: [], rest_count: 0}

        text ->
          agency_matches = agency_matches(agency_options, text)
          route_matches = Enum.map(route_options.matches, &route_entry/1)
          bounded(agency_matches ++ route_matches, route_options.rest_count)
      end

    Map.put(suggestions, :tokens, agency_tokens ++ route_tokens)
  end

  # The agencies the filter does not name whose name holds `text`, in the
  # order of their options within each rank.
  defp agency_matches(agency_options, text) do
    ranked =
      for %{checked: false} = option <- agency_options,
          name = String.downcase(option.name),
          String.contains?(name, text) do
        {rank(String.starts_with?(name, text)), agency_entry(option)}
      end

    ranked
    |> Enum.with_index()
    |> Enum.sort_by(fn {{rank, _entry}, index} -> {rank, index} end)
    |> Enum.map(fn {{_rank, entry}, _index} -> entry end)
  end

  defp rank(true = _starts_with), do: 0
  defp rank(false = _starts_with), do: 1

  defp bounded(matches, left_out_count) do
    kept = Enum.take(matches, RouteOptions.match_count_max())
    %{suggestions: kept, rest_count: length(matches) - length(kept) + left_out_count}
  end

  defp agency_entry(%{id: id, name: name}) do
    %{field: @agency_field, id: id, name: name, detail: nil, agency_name: nil}
  end

  defp route_entry(%{id: id, name: name, detail: detail, agency_name: agency_name}) do
    %{field: @route_field, id: id, name: name, detail: detail, agency_name: agency_name}
  end
end
