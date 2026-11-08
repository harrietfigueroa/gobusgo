defmodule GobusgoWeb.FilterBarTest do
  # Verifies the tokens and the suggestions of a filter bar as a pure
  # function: each case names the agencies and the route fetches the views
  # hold, the agencies and routes a filter names, and the text a rider
  # typed, and the entries a page must show.
  use ExUnit.Case, async: true

  alias GobusgoWeb.FilterBar
  alias GobusgoWeb.RouteOptions

  @agencies [
    %{id: "1", name: "Metro Transit"},
    %{id: "40", name: "Sound Transit"},
    %{id: "29", name: "Community Transit"}
  ]

  # A route is `{identifier, short name, long name}`.
  defp fetch(agency_id, routes) do
    %{
      id: agency_id,
      route_ids: for({id, _short_name, _long_name} <- routes, do: id),
      routes:
        for {id, short_name, long_name} <- routes, into: %{} do
          {id, %{"agencyId" => agency_id, "shortName" => short_name, "longName" => long_name}}
        end
    }
  end

  defp options(overrides) do
    FilterBar.options(
      Map.merge(
        %{
          agencies: @agencies,
          route_fetches: [
            fetch("1", [{"1_40", "40", "Ballard - Northgate"}, {"1_8", "8", nil}]),
            fetch("40", [{"40_550", "550", nil}, {"40_1", "1 Line", "Lynnwood - Angle Lake"}])
          ],
          agency_ids: [],
          route_ids: [],
          query: ""
        },
        overrides
      )
    )
  end

  defp entries(entries), do: for(entry <- entries, do: {entry.field, entry.id})

  describe "tokens" do
    test "name the filter's agencies, then its routes" do
      %{tokens: tokens} = options(%{agency_ids: ["40", "1"], route_ids: ["1_8"]})

      assert entries(tokens) == [{"agency", "1"}, {"agency", "40"}, {"route", "1_8"}]
    end

    test "name an agency by the agency view's name" do
      %{tokens: [token]} = options(%{agency_ids: ["40"]})

      assert token == %{
               field: "agency",
               id: "40",
               name: "Sound Transit",
               detail: nil,
               agency_name: nil
             }
    end

    test "name a route as the route options do" do
      %{tokens: [token]} = options(%{route_ids: ["1_40"]})

      assert token == %{
               field: "route",
               id: "1_40",
               name: "40",
               detail: "Ballard - Northgate",
               agency_name: "Metro Transit"
             }
    end

    test "name an agency and a route the views do not hold by their identifiers" do
      %{tokens: tokens} = options(%{agency_ids: ["97"], route_ids: ["1_999"]})

      assert for(token <- tokens, do: token.name) == ["97", "1_999"]
    end

    test "stay whatever the text" do
      %{tokens: tokens} = options(%{agency_ids: ["1"], query: "550"})

      assert entries(tokens) == [{"agency", "1"}]
    end
  end

  describe "suggestions" do
    test "are none for no text" do
      assert %{suggestions: [], rest_count: 0} = options(%{query: ""})
    end

    test "are none for text of spaces alone" do
      assert %{suggestions: [], rest_count: 0} = options(%{query: "   "})
    end

    test "hold the agencies whose name holds the text, in name order" do
      %{suggestions: suggestions} = options(%{query: "transit"})

      assert entries(suggestions) == [{"agency", "29"}, {"agency", "1"}, {"agency", "40"}]
    end

    test "put an agency whose name starts with the text before one that holds it" do
      %{suggestions: suggestions} = options(%{query: "s"})

      assert [{"agency", "40"} | _rest] = entries(suggestions)
    end

    test "hold the agencies first, then the routes" do
      route_fetches = [fetch("1", [{"1_m", "Metro Shuttle", nil}])]

      %{suggestions: suggestions} = options(%{route_fetches: route_fetches, query: "metro"})

      assert entries(suggestions) == [{"agency", "1"}, {"route", "1_m"}]
    end

    test "hold the routes whose name holds the text, as the route options narrow them" do
      %{suggestions: suggestions} = options(%{query: "55"})

      assert entries(suggestions) == [{"route", "40_550"}]
    end

    test "match an agency whatever the case" do
      %{suggestions: suggestions} = options(%{query: "METRO"})

      assert entries(suggestions) == [{"agency", "1"}]
    end

    test "leave out an agency the filter names" do
      %{suggestions: suggestions} = options(%{agency_ids: ["1"], query: "transit"})

      assert entries(suggestions) == [{"agency", "29"}, {"agency", "40"}]
    end

    test "leave the text's case and spaces to the matching" do
      %{suggestions: suggestions} = options(%{query: "  Sound "})

      assert entries(suggestions) == [{"agency", "40"}]
    end

    test "leave out a route the filter names" do
      %{suggestions: suggestions} = options(%{route_ids: ["1_40"], query: "40"})

      assert entries(suggestions) == []
    end

    test "hold the routes of the agencies the filter names alone" do
      %{suggestions: suggestions} = options(%{agency_ids: ["40"], query: "5"})

      assert entries(suggestions) == [{"route", "40_550"}]
    end

    test "hold at most the route options' count of matches, agencies included" do
      count = RouteOptions.match_count_max() + 3
      routes = for number <- 1..count, do: {"1_t#{number}", "T#{number}", nil}

      %{suggestions: suggestions, rest_count: rest_count} =
        options(%{route_fetches: [fetch("1", routes)], query: "t"})

      assert length(suggestions) == RouteOptions.match_count_max()
      assert rest_count == count + 3 - RouteOptions.match_count_max()
      assert [{"agency", _id} | _rest] = entries(suggestions)
    end
  end
end
