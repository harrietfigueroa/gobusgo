defmodule Gobusgo.OneBusAway.DemandKeyTest do
  # Verifies the demand keys of the OneBusAway datasets as pure functions,
  # and against a registry started with the datasets the module names.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Demand
  alias Gobusgo.OneBusAway.DemandKey

  test "the key of a stop's arrivals is in the arrivals dataset, with the stop as its item" do
    assert DemandKey.arrivals("1_100") == {DemandKey.arrivals_dataset(), "1_100"}
  end

  test "the keys of two stops differ" do
    assert DemandKey.arrivals("1_100") != DemandKey.arrivals("1_200")
  end

  test "raises for an empty stop identifier" do
    assert_raise AssertionError, ~r/stop identifier/, fn -> DemandKey.arrivals("") end
  end

  test "the vehicles key is outside the arrivals dataset" do
    {dataset, _item} = DemandKey.vehicles()

    assert dataset != DemandKey.arrivals_dataset()
  end

  test "a registry of the datasets admits both keys", context do
    registry = Module.concat(__MODULE__, "Registry#{context.line}")
    start_supervised!({Demand, name: registry, datasets: DemandKey.datasets()})

    assert Demand.register(registry, DemandKey.vehicles()) == :ok
    assert Demand.register(registry, DemandKey.arrivals("1_100")) == :ok
    assert Demand.items(registry, DemandKey.arrivals_dataset()) == ["1_100"]
  end
end
