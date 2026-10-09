defmodule GobusgoWeb.RouteOptions do
  @match_count_max 20
  @query_length_max 64

  @moduledoc """
  The options a page offers for a filter by route: the routes the filter
  selects, and the routes a rider can add to it, narrowed by the text the
  rider typed. Everything here is pure.

  An option names its route as a map page's list of routes does: `name` is
  the route's short name, or its long name where it has no short name, or
  its identifier where it has neither; `detail` is the long name beside a
  short name; and `agency_name` is the name of the agency the route's own
  record names, `nil` for an agency that is not named. They are text from
  outside the application, which a page hands on as data.

  The selected options come first, whatever the text and the agencies, so a
  page can show and remove every route of its filter. A selected route that
  no fetch lists is named by its identifier and comes after the others.

  The matches are the routes of the named agencies, or of every agency when
  none is named, whose name holds the text, whatever its case. A route that
  has a short name is found by it alone. The matches whose name starts with
  the text come first, and within that the order is the natural order of
  the names, so route 8 stands before route 40, then the agency's name,
  then the identifier. A page gets at most #{@match_count_max} matches and
  the count of the rest. The text is at most #{@query_length_max}
  characters.
  """

  alias Gobusgo.Assert

  @type option :: %{
          id: String.t(),
          name: String.t(),
          detail: String.t() | nil,
          agency_name: String.t() | nil,
          checked: boolean()
        }

  @doc "The most matches `options/1` returns."
  @spec match_count_max() :: pos_integer()
  def match_count_max, do: @match_count_max

  @doc "The most characters of typed text that `query/1` keeps."
  @spec query_length_max() :: pos_integer()
  def query_length_max, do: @query_length_max

  @doc """
  Returns the text to narrow by that `value` holds, a form field as a
  transport decodes it: its first #{@query_length_max} characters, and the
  empty text for a value that is not text.
  """
  @spec query(term()) :: String.t()
  def query(value) when is_binary(value), do: String.slice(value, 0, @query_length_max)
  def query(_value), do: ""

  @doc """
  Returns the options for the routes of `route_fetches`, the current fetches
  of the route view, under a filter that selects the routes `selected_ids`
  and the agencies `agency_ids`, none for every agency, narrowed by `query`.
  `agency_names` holds the name of each agency by its identifier.
  `rest_count` is the count of the matches left out.
  """
  @spec options(%{
          route_fetches: [map()],
          agency_names: %{String.t() => String.t()},
          agency_ids: [String.t()],
          selected_ids: [String.t()],
          query: String.t()
        }) :: %{selected: [option()], matches: [option()], rest_count: non_neg_integer()}
  def options(%{
        route_fetches: route_fetches,
        agency_names: agency_names,
        agency_ids: agency_ids,
        selected_ids: selected_ids,
        query: query
      })
      when is_list(route_fetches) and is_map(agency_names) and is_list(agency_ids) and
             is_list(selected_ids) and is_binary(query) do
    Assert.condition(
      String.length(query) <= @query_length_max,
      "query must be at most #{@query_length_max} characters, got: #{String.length(query)}"
    )

    selected_ids = MapSet.new(selected_ids)
    listed = Enum.flat_map(route_fetches, &listed_options(&1, agency_names))
    {held_selected, unselected} = Enum.split_with(listed, &MapSet.member?(selected_ids, &1.id))

    matched = matched_options(unselected, %{agency_ids: agency_ids, query: query})
    matches = Enum.take(matched, @match_count_max)

    %{
      selected: selected_options(held_selected, selected_ids),
      matches: Enum.map(matches, &option(&1, false)),
      rest_count: length(matched) - length(matches)
    }
  end

  # Every route a fetch lists, with the agency whose fetch lists it, which
  # is what the agencies of a filter are judged by.
  defp listed_options(
         %{id: listing_agency_id, route_ids: route_ids, routes: routes},
         agency_names
       ) do
    for route_id <- route_ids do
      route = Map.fetch!(routes, route_id)
      short_name = route["shortName"]
      long_name = route["longName"]

      # A long name that stands in for the short name is not said twice.
      detail =
        case short_name do
          nil -> nil
          _short_name -> long_name
        end

      %{
        id: route_id,
        listing_agency_id: listing_agency_id,
        name: short_name || long_name || route_id,
        detail: detail,
        agency_name: Map.get(agency_names, route["agencyId"])
      }
    end
  end

  defp selected_options(held_selected, selected_ids) do
    held_ids = MapSet.new(held_selected, & &1.id)

    unheld =
      for id <- Enum.sort(selected_ids), not MapSet.member?(held_ids, id) do
        %{id: id, name: id, detail: nil, agency_name: nil, checked: true}
      end

    # A route two agencies list is one option.
    held =
      held_selected
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(&order/1)
      |> Enum.map(&option(&1, true))

    held ++ unheld
  end

  defp matched_options(unselected, %{agency_ids: agency_ids, query: query}) do
    text = query |> String.trim() |> String.downcase()

    ranked =
      for listed <- unselected,
          agency_ids == [] or listed.listing_agency_id in agency_ids,
          rank = rank(String.downcase(listed.name), text),
          rank != nil do
        {rank, listed}
      end

    ranked
    |> Enum.uniq_by(fn {_rank, listed} -> listed.id end)
    |> Enum.sort_by(fn {rank, listed} -> {rank, order(listed)} end)
    |> Enum.map(fn {_rank, listed} -> listed end)
  end

  # Where a name stands among the matches of a text: first when it starts
  # with the text, then when it holds it, and nowhere otherwise.
  defp rank(name, text) do
    cond do
      String.starts_with?(name, text) -> 0
      String.contains?(name, text) -> 1
      true -> nil
    end
  end

  defp order(listed), do: {natural(listed.name), natural(listed.agency_name || ""), listed.id}

  # A name as the runs of digits and of other characters it is made of, a
  # run of digits as its number, so that names compare in natural order.
  defp natural(name) do
    for run <- Regex.split(~r/\d+/, String.downcase(name), include_captures: true, trim: true) do
      case Integer.parse(run) do
        {number, ""} -> {0, number}
        _not_a_number -> {1, run}
      end
    end
  end

  defp option(listed, checked) do
    %{
      id: listed.id,
      name: listed.name,
      detail: listed.detail,
      agency_name: listed.agency_name,
      checked: checked
    }
  end
end
