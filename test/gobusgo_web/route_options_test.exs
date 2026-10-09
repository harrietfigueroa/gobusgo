defmodule GobusgoWeb.RouteOptionsTest do
  # Verifies the options of a route filter as a pure function: each case
  # names the fetches a route view holds, the agencies and routes a filter
  # selects, and the text a rider typed, and the options a page must offer.
  use ExUnit.Case, async: true

  alias GobusgoWeb.RouteOptions

  @agency_names %{"1" => "Metro Transit", "40" => "Sound Transit"}

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
    RouteOptions.options(
      Map.merge(
        %{
          route_fetches: [
            fetch("1", [
              {"1_40", "40", "Ballard - Northgate"},
              {"1_8", "8", nil},
              {"1_140", "140", nil}
            ]),
            fetch("40", [{"40_550", "550", "Bellevue - Seattle"}, {"40_40", "40", nil}])
          ],
          agency_names: @agency_names,
          agency_ids: [],
          selected_ids: [],
          query: ""
        },
        overrides
      )
    )
  end

  defp ids(options), do: Enum.map(options, & &1.id)

  describe "an option" do
    test "names a route by its short name, with its long name and its agency beside it" do
      assert %{matches: [option]} = options(%{query: "550"})

      assert option == %{
               id: "40_550",
               name: "550",
               detail: "Bellevue - Seattle",
               agency_name: "Sound Transit",
               checked: false
             }
    end

    test "names a route with no short name by its long name, with no detail" do
      fetches = [fetch("95", [{"95_73", nil, "Seattle - Bainbridge Island"}])]

      assert %{matches: [%{name: "Seattle - Bainbridge Island", detail: nil}]} =
               options(%{route_fetches: fetches})
    end

    test "names a route with neither name by its identifier" do
      fetches = [fetch("1", [{"1_7994", nil, nil}])]

      assert %{matches: [%{name: "1_7994", detail: nil}]} = options(%{route_fetches: fetches})
    end

    test "has no agency name for a route whose agency is not named" do
      assert %{matches: [%{agency_name: nil}]} = options(%{agency_names: %{}, query: "550"})
    end
  end

  describe "the matches" do
    test "are every route in natural name order, then by agency name, without text" do
      assert %{matches: matches, rest_count: 0} = options(%{})

      assert ids(matches) == ["1_8", "1_40", "40_40", "1_140", "40_550"]
    end

    test "are the routes whose name holds the text, those that start with it first" do
      assert %{matches: matches} = options(%{query: "40"})

      assert ids(matches) == ["1_40", "40_40", "1_140"]
    end

    test "ignore the case of the text and the space around it" do
      fetches = [fetch("95", [{"95_73", nil, "Seattle - Bainbridge Island"}])]

      assert %{matches: [%{id: "95_73"}]} = options(%{route_fetches: fetches, query: " BAIN "})
    end

    test "do not search the long name of a route that has a short name" do
      assert %{matches: []} = options(%{query: "Ballard"})
    end

    test "are the routes of the named agencies alone" do
      assert %{matches: matches} = options(%{agency_ids: ["40"]})

      assert ids(matches) == ["40_40", "40_550"]
    end

    test "leave out a selected route" do
      assert %{matches: matches} = options(%{selected_ids: ["1_40"], query: "40"})

      assert ids(matches) == ["40_40", "1_140"]
    end

    test "are none when no fetch lists a route" do
      assert %{matches: [], rest_count: 0} = options(%{route_fetches: []})
    end

    test "are at most the bound, with the count of the rest" do
      count = RouteOptions.match_count_max() + 3
      fetches = [fetch("1", for(number <- 1..count, do: {"1_#{number}", "#{number}", nil}))]

      assert %{matches: matches, rest_count: 3} = options(%{route_fetches: fetches})
      assert length(matches) == RouteOptions.match_count_max()
      assert hd(matches).id == "1_1"
    end
  end

  describe "the selected options" do
    test "are the selected routes, checked, in name order, whatever the text" do
      assert %{selected: selected} = options(%{selected_ids: ["40_550", "1_8"], query: "zzz"})

      assert [%{id: "1_8", checked: true}, %{id: "40_550", checked: true}] = selected
    end

    test "hold a selected route of an agency that is not named" do
      assert %{selected: [%{id: "1_8", name: "8"}]} =
               options(%{selected_ids: ["1_8"], agency_ids: ["40"]})
    end

    test "hold a selected route no fetch lists, named by its identifier, last" do
      assert %{selected: selected} = options(%{selected_ids: ["zz_1", "1_8"]})

      assert selected == [
               %{id: "1_8", name: "8", detail: nil, agency_name: "Metro Transit", checked: true},
               %{id: "zz_1", name: "zz_1", detail: nil, agency_name: nil, checked: true}
             ]
    end

    test "are none without a selection" do
      assert %{selected: []} = options(%{})
    end
  end

  describe "a query as a rider typed it" do
    test "is kept to the bound on its length" do
      text = String.duplicate("a", RouteOptions.query_length_max() + 5)

      assert String.length(RouteOptions.query(text)) == RouteOptions.query_length_max()
    end

    test "is empty for anything that is not text" do
      assert RouteOptions.query(%{"x" => "1"}) == ""
      assert RouteOptions.query(nil) == ""
    end
  end
end
