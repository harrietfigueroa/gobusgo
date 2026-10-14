defmodule GobusgoWeb.VehicleLive.FilterTest do
  # Checks what a vehicle page's filter is for each source it comes from,
  # and what a filter and a refused filter answer, by calling the pure
  # functions with literal filters and route fetches.
  use ExUnit.Case, async: true

  alias GobusgoWeb.VehicleLive.Filter

  @route_fetches [
    %{id: "1", route_ids: ["1_100", "1_200"]},
    %{id: "40", route_ids: ["40_300"]}
  ]

  describe "raw/1 and normalize/1" do
    test "an address's parameters give the filter they name" do
      raw = Filter.raw(%{"agency" => "40,1", "route" => "1_100", "other" => "x"})

      assert Filter.normalize(raw) == %{"agency" => ["1", "40"], "route" => ["1_100"]}
    end

    test "parameters that name no field give the filter of every vehicle" do
      assert Filter.normalize(Filter.raw(%{"other" => "x"})) == %{}
    end

    test "a raw filter the contract does not accept is refused" do
      assert Filter.normalize(%{"agency" => 1}) == :refused
    end
  end

  describe "stored/1" do
    for {name, params, filter} <- [
          {"a stored filter is judged as a raw filter", %{"filter" => %{"agency" => ["1"]}},
           %{"agency" => ["1"]}},
          {"a stored filter the contract does not accept is refused",
           %{"filter" => %{"agency" => 1}}, :refused},
          {"a stored value that is no map is refused", %{"filter" => "agency=1"}, :refused},
          {"parameters with no filter are refused", %{}, :refused}
        ] do
      test name do
        assert Filter.stored(unquote(Macro.escape(params))) == unquote(Macro.escape(filter))
      end
    end
  end

  describe "changed/1" do
    for {name, raw, filter} <- [
          {"a change that names agencies keeps the routes one of them lists",
           %{"agency" => ["1"], "route" => ["1_100", "40_300"]},
           %{"agency" => ["1"], "route" => ["1_100"]}},
          {"a change whose agencies list none of its routes names no route",
           %{"agency" => ["40"], "route" => ["1_100"]}, %{"agency" => ["40"]}},
          {"a change that names no agency keeps every route", %{"route" => ["1_100", "9_900"]},
           %{"route" => ["1_100", "9_900"]}},
          {"a change that names no route is left as it is", %{"agency" => ["7"]},
           %{"agency" => ["7"]}},
          {"a change the contract does not accept is refused", %{"agency" => 1}, :refused}
        ] do
      test name do
        changed =
          Filter.changed(%{raw: unquote(Macro.escape(raw)), route_fetches: @route_fetches})

        assert changed == unquote(Macro.escape(filter))
      end
    end
  end

  describe "what a filter names" do
    for {name, filter, agency_ids, route_ids, single_agency_id} <- [
          {"a filter of both fields", %{"agency" => ["1"], "route" => ["1_100"]}, ["1"],
           ["1_100"], "1"},
          {"a filter of several agencies", %{"agency" => ["1", "40"]}, ["1", "40"], [], nil},
          {"a filter of no field", %{}, [], [], nil},
          {"a refused filter", :refused, [], [], nil}
        ] do
      test name do
        filter = unquote(Macro.escape(filter))

        assert Filter.agency_ids(filter) == unquote(agency_ids)
        assert Filter.route_ids(filter) == unquote(route_ids)
        assert Filter.single_agency_id(filter) == unquote(single_agency_id)
      end
    end
  end

  describe "keeps_agency?/2" do
    for {name, filter, agency_id, kept} <- [
          {"a filter that names the agency keeps it", %{"agency" => ["1"]}, "1", true},
          {"a filter that names another agency does not", %{"agency" => ["1"]}, "40", false},
          {"a filter that names no agency keeps every agency", %{}, "40", true},
          {"a refused filter keeps no agency", :refused, "1", false}
        ] do
      test name do
        assert Filter.keeps_agency?(unquote(Macro.escape(filter)), unquote(agency_id)) ==
                 unquote(kept)
      end
    end
  end
end
