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

  describe "spec/0" do
    test "names the agency field" do
      assert VehicleFilter.spec() == %{"agency" => :string}
    end
  end

  describe "normalize/1" do
    test "returns the filter for agencies" do
      assert VehicleFilter.normalize(%{"agency" => ["40", "1"]}) ==
               {:ok, %{"agency" => ["1", "40"]}}
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
      assert VehicleFilter.values(%{agency_id: "40", vehicle: %{"id" => "40_1"}}) ==
               %{"agency" => "40"}
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

    test "raises for a filter on a field outside the specification" do
      assert_raise Gobusgo.Assert.AssertionError, fn ->
        VehicleFilter.filter_fetch(%{filter: %{"color" => ["red"]}, fetch: fetch("40", ["40_1"])})
      end
    end
  end

  test "is an adapter of the filter contract" do
    behaviours = VehicleFilter.module_info(:attributes)[:behaviour]

    assert Filter in behaviours
  end
end
