defmodule Gobusgo.OneBusAway.VehicleFilterTest do
  # Verifies the vehicle adapter of the filter contract as pure functions
  # over a literal fetch in the form the vehicle view holds: which raw
  # filters it accepts, and which vehicles of a fetch a filter keeps.
  use ExUnit.Case, async: true

  alias Gobusgo.Filter
  alias Gobusgo.OneBusAway.VehicleFilter

  defp fetch(agency_id, vehicle_ids) do
    %{
      agency_id: agency_id,
      request_id: "0199c4a2-7e1b-7a3f-9d20-000000000001",
      fetched_at: ~U[2026-10-02 03:15:00Z],
      vehicle_ids: vehicle_ids,
      vehicles: Map.new(vehicle_ids, &{&1, %{"id" => &1}})
    }
  end

  # A fetch whose vehicles are each `{vehicle id, route id}`, in that order.
  defp fetch_on_routes(agency_id, vehicle_routes) do
    fetch =
      fetch(agency_id, Enum.map(vehicle_routes, fn {vehicle_id, _route_id} -> vehicle_id end))

    vehicles =
      Map.new(vehicle_routes, fn {vehicle_id, route_id} ->
        {vehicle_id, %{"id" => vehicle_id, "routeId" => route_id}}
      end)

    %{fetch | vehicles: vehicles}
  end

  describe "spec/0" do
    test "names the agency and route fields" do
      assert VehicleFilter.spec() == %{"agency" => :string, "route" => :string}
    end
  end

  describe "normalize/1" do
    test "returns the filter for agencies" do
      assert VehicleFilter.normalize(%{"agency" => ["40", "1"]}) ==
               {:ok, %{"agency" => ["1", "40"]}}
    end

    test "returns the filter for routes" do
      assert VehicleFilter.normalize(%{"route" => ["40_532", "1_100479"]}) ==
               {:ok, %{"route" => ["1_100479", "40_532"]}}
    end

    test "returns the filter for agencies and routes together" do
      assert VehicleFilter.normalize(%{"agency" => "1", "route" => ["1_100479"]}) ==
               {:ok, %{"agency" => ["1"], "route" => ["1_100479"]}}
    end

    test "returns the empty filter for no field" do
      assert VehicleFilter.normalize(%{}) == {:ok, %{}}
    end

    test "refuses a field that vehicles are not filtered by" do
      assert VehicleFilter.normalize(%{"color" => "red"}) ==
               {:error, [%{field: "color", reason: :unknown_field}]}
    end
  end

  describe "values/1" do
    test "holds the agency of the vehicle's fetch" do
      values = VehicleFilter.values(%{agency_id: "40", vehicle: %{"id" => "40_1"}})

      assert values["agency"] == "40"
    end

    test "holds the route of the vehicle's trip" do
      vehicle = %{"id" => "40_1", "routeId" => "40_532"}

      assert VehicleFilter.values(%{agency_id: "40", vehicle: vehicle})["route"] == "40_532"
    end

    for {description, vehicle} <- [
          {"a vehicle whose route is null", %{"id" => "40_1", "routeId" => nil}},
          {"a vehicle that names no route", %{"id" => "40_1"}}
        ] do
      test "holds no route for #{description}" do
        values = VehicleFilter.values(%{agency_id: "40", vehicle: unquote(Macro.escape(vehicle))})

        assert values["route"] == nil
      end
    end

    test "holds a value for every field of the specification" do
      values = VehicleFilter.values(%{agency_id: "40", vehicle: %{"id" => "40_1"}})

      assert Map.keys(values) == Map.keys(VehicleFilter.spec())
    end
  end

  describe "filter_fetch/1" do
    test "keeps every vehicle of an agency the filter accepts" do
      fetch = fetch("40", ["40_1", "40_2"])

      assert VehicleFilter.filter_fetch(%{filter: %{"agency" => ["1", "40"]}, fetch: fetch}) ==
               fetch
    end

    test "keeps every vehicle under the empty filter" do
      fetch = fetch("40", ["40_1", "40_2"])

      assert VehicleFilter.filter_fetch(%{filter: %{}, fetch: fetch}) == fetch
    end

    test "keeps no vehicle of an agency the filter does not accept, and the fetch it came from" do
      fetch = fetch("40", ["40_1", "40_2"])

      assert VehicleFilter.filter_fetch(%{filter: %{"agency" => ["1"]}, fetch: fetch}) ==
               %{fetch | vehicle_ids: [], vehicles: %{}}
    end

    test "returns a fetch with no vehicle as it is" do
      fetch = fetch("40", [])

      assert VehicleFilter.filter_fetch(%{filter: %{"agency" => ["40"]}, fetch: fetch}) == fetch
    end

    test "keeps the vehicles on a route the filter names, in the fetch's order" do
      fetch =
        fetch_on_routes("1", [{"1_c", "1_100479"}, {"1_a", "1_100252"}, {"1_b", "1_100479"}])

      kept = VehicleFilter.filter_fetch(%{filter: %{"route" => ["1_100479"]}, fetch: fetch})

      assert kept.vehicle_ids == ["1_c", "1_b"]
    end

    test "returns only the kept vehicles' records" do
      fetch = fetch_on_routes("1", [{"1_a", "1_100252"}, {"1_b", "1_100479"}])

      kept = VehicleFilter.filter_fetch(%{filter: %{"route" => ["1_100479"]}, fetch: fetch})

      assert kept.vehicles == Map.take(fetch.vehicles, ["1_b"])
    end

    test "keeps the vehicles on any of the routes the filter names" do
      fetch =
        fetch_on_routes("1", [{"1_a", "1_100252"}, {"1_b", "1_100479"}, {"1_c", "1_100001"}])

      kept =
        VehicleFilter.filter_fetch(%{
          filter: %{"route" => ["1_100252", "1_100479"]},
          fetch: fetch
        })

      assert kept.vehicle_ids == ["1_a", "1_b"]
    end

    test "keeps the vehicles of a named agency on a named route" do
      fetch = fetch_on_routes("1", [{"1_a", "1_100252"}, {"1_b", "1_100479"}])

      kept =
        VehicleFilter.filter_fetch(%{
          filter: %{"agency" => ["1"], "route" => ["1_100479"]},
          fetch: fetch
        })

      assert kept.vehicle_ids == ["1_b"]
    end

    test "keeps no vehicle on a named route in a fetch of an agency the filter leaves out" do
      fetch = fetch_on_routes("40", [{"40_a", "40_532"}])

      kept =
        VehicleFilter.filter_fetch(%{
          filter: %{"agency" => ["1"], "route" => ["40_532"]},
          fetch: fetch
        })

      assert kept.vehicle_ids == []
    end

    test "keeps no vehicle when no vehicle is on a route the filter names" do
      fetch = fetch_on_routes("1", [{"1_a", "1_100252"}])

      assert VehicleFilter.filter_fetch(%{filter: %{"route" => ["1_100479"]}, fetch: fetch}) ==
               %{fetch | vehicle_ids: [], vehicles: %{}}
    end

    for {description, vehicle} <- [
          {"a vehicle whose route is null", %{"id" => "1_a", "routeId" => nil}},
          {"a vehicle that names no route", %{"id" => "1_a"}}
        ] do
      test "leaves #{description} out under a filter that names a route" do
        fetch = %{fetch("1", ["1_a"]) | vehicles: %{"1_a" => unquote(Macro.escape(vehicle))}}

        kept = VehicleFilter.filter_fetch(%{filter: %{"route" => ["1_100479"]}, fetch: fetch})

        assert kept.vehicle_ids == []
      end

      test "keeps #{description} under a filter that names its agency alone" do
        fetch = %{fetch("1", ["1_a"]) | vehicles: %{"1_a" => unquote(Macro.escape(vehicle))}}

        kept = VehicleFilter.filter_fetch(%{filter: %{"agency" => ["1"]}, fetch: fetch})

        assert kept.vehicle_ids == ["1_a"]
      end
    end

    test "raises for a filter on a field outside the specification" do
      assert_raise Gobusgo.Assert.AssertionError, fn ->
        VehicleFilter.filter_fetch(%{filter: %{"color" => ["red"]}, fetch: fetch("40", ["40_1"])})
      end
    end
  end

  describe "keeps_agency?/1" do
    for {description, filter, kept} <- [
          {"the empty filter", %{}, true},
          {"a filter that names the agency", %{"agency" => ["1", "40"]}, true},
          {"a filter that names other agencies", %{"agency" => ["1"]}, false},
          {"a filter that names routes alone", %{"route" => ["1_100479"]}, true},
          {"a filter that names the agency and routes",
           %{"agency" => ["40"], "route" => ["1_100479"]}, true},
          {"a filter that names other agencies and routes",
           %{"agency" => ["1"], "route" => ["40_532"]}, false}
        ] do
      test "is #{kept} for #{description}" do
        assert VehicleFilter.keeps_agency?(%{
                 filter: unquote(Macro.escape(filter)),
                 agency_id: "40"
               }) == unquote(kept)
      end
    end
  end

  test "is an adapter of the filter contract" do
    behaviours = VehicleFilter.module_info(:attributes)[:behaviour]

    assert Filter in behaviours
  end
end
