defmodule Gobusgo.Demand.StateTest do
  # Verifies the rules of demand as pure functions: each case registers and
  # releases keys for holders that are plain atoms and reads the outcome,
  # the items of a dataset, and the holders of a key.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Demand.State

  @full [{:a, {:arrivals, "1_1"}}, {:b, {:arrivals, "1_2"}}, {:c, {:arrivals, "1_3"}}]

  defp new(settings \\ %{}) do
    State.new(
      Map.merge(
        %{datasets: [:arrivals, :vehicles], item_count_max: 3, holder_item_count_max: 2},
        settings
      )
    )
  end

  defp register_all(state, registrations) do
    Enum.reduce(registrations, state, fn {holder, key}, state ->
      {state, :registered} = State.register(state, %{holder: holder, key: key})
      state
    end)
  end

  test "no dataset has an item at first" do
    assert State.items(new(), :arrivals) == []
  end

  test "an item a holder registers is an item of its dataset" do
    assert {state, :registered} =
             State.register(new(), %{holder: :a, key: {:arrivals, "1_100"}})

    assert State.items(state, :arrivals) == ["1_100"]
  end

  test "the items of a dataset are sorted and each named once" do
    state =
      register_all(new(), [
        {:a, {:arrivals, "1_300"}},
        {:b, {:arrivals, "1_100"}},
        {:c, {:arrivals, "1_300"}}
      ])

    assert State.items(state, :arrivals) == ["1_100", "1_300"]
  end

  test "the items of a dataset leave out those of another" do
    state = register_all(new(), [{:a, {:arrivals, "1_100"}}, {:a, {:vehicles, "all"}}])

    assert State.items(state, :arrivals) == ["1_100"]
  end

  test "registering a key the holder holds changes nothing" do
    state = register_all(new(), [{:a, {:arrivals, "1_100"}}])

    assert State.register(state, %{holder: :a, key: {:arrivals, "1_100"}}) ==
             {state, :already_registered}
  end

  test "an item stays while another holder holds its key" do
    state = register_all(new(), [{:a, {:arrivals, "1_100"}}, {:b, {:arrivals, "1_100"}}])

    state = State.release(state, %{holder: :a, key: {:arrivals, "1_100"}})

    assert State.items(state, :arrivals) == ["1_100"]
  end

  test "an item whose last holder releases its key is gone" do
    state = register_all(new(), [{:a, {:arrivals, "1_100"}}])

    state = State.release(state, %{holder: :a, key: {:arrivals, "1_100"}})

    assert state == new()
  end

  for {name, registration} <- [
        {"another holder", %{holder: :b, key: {:arrivals, "1_100"}}},
        {"another item", %{holder: :a, key: {:arrivals, "1_999"}}},
        {"another dataset", %{holder: :a, key: {:vehicles, "1_100"}}}
      ] do
    test "releasing a key the holder does not hold changes nothing: #{name}" do
      state = register_all(new(), [{:a, {:arrivals, "1_100"}}])

      assert State.release(state, unquote(Macro.escape(registration))) == state
    end
  end

  test "releasing every key of a holder leaves the keys of the others" do
    state =
      register_all(new(), [
        {:a, {:arrivals, "1_100"}},
        {:a, {:arrivals, "1_200"}},
        {:a, {:vehicles, "all"}},
        {:b, {:arrivals, "1_200"}}
      ])

    state = State.release_all(state, :a)

    assert State.items(state, :arrivals) == ["1_200"]
    assert State.items(state, :vehicles) == []
    refute State.holder?(state, :a)
    assert State.holder?(state, :b)
  end

  test "releasing every key of a holder that has none changes nothing" do
    state = register_all(new(), [{:a, {:arrivals, "1_100"}}])

    assert State.release_all(state, :b) == state
  end

  test "a holder of a key in any dataset is a holder" do
    state = register_all(new(), [{:a, {:vehicles, "all"}}])

    assert State.holder?(state, :a)
  end

  describe "holder_count/2" do
    test "is zero for a key nobody holds" do
      assert State.holder_count(new(), {:vehicles, "all"}) == 0
    end

    test "counts each holder of the key once" do
      state =
        register_all(new(), [
          {:a, {:vehicles, "all"}},
          {:b, {:vehicles, "all"}},
          {:c, {:arrivals, "all"}}
        ])

      {state, :already_registered} = State.register(state, %{holder: :a, key: {:vehicles, "all"}})

      assert State.holder_count(state, {:vehicles, "all"}) == 2
    end

    test "drops by one when a holder releases the key" do
      state = register_all(new(), [{:a, {:vehicles, "all"}}, {:b, {:vehicles, "all"}}])

      state = State.release(state, %{holder: :a, key: {:vehicles, "all"}})

      assert State.holder_count(state, {:vehicles, "all"}) == 1
    end
  end

  describe "bounds" do
    test "a dataset holds as many items as the bound allows" do
      state = register_all(new(), @full)

      assert State.items(state, :arrivals) == ["1_1", "1_2", "1_3"]
    end

    test "an item beyond the bound of its dataset is refused" do
      state = register_all(new(), @full)

      assert State.register(state, %{holder: :d, key: {:arrivals, "1_4"}}) ==
               {state, :item_count_exceeded}
    end

    test "a dataset at its bound leaves another dataset its own" do
      state = register_all(new(), @full)

      assert {_state, :registered} = State.register(state, %{holder: :d, key: {:vehicles, "all"}})
    end

    test "an item the dataset has already is registered at the bound" do
      state = register_all(new(), @full)

      assert {_state, :registered} = State.register(state, %{holder: :d, key: {:arrivals, "1_3"}})
    end

    test "a released item leaves its place to another" do
      state = register_all(new(), @full)
      state = State.release(state, %{holder: :a, key: {:arrivals, "1_1"}})

      assert {_state, :registered} = State.register(state, %{holder: :d, key: {:arrivals, "1_4"}})
    end

    test "a holder's item beyond its own bound in the dataset is refused" do
      state = register_all(new(), [{:a, {:arrivals, "1_1"}}, {:a, {:arrivals, "1_2"}}])

      assert State.register(state, %{holder: :a, key: {:arrivals, "1_3"}}) ==
               {state, :holder_item_count_exceeded}
    end

    test "a holder at its bound in one dataset registers an item of another" do
      state = register_all(new(), [{:a, {:arrivals, "1_1"}}, {:a, {:arrivals, "1_2"}}])

      assert {_state, :registered} = State.register(state, %{holder: :a, key: {:vehicles, "all"}})
    end

    test "as many datasets as the bound allows are admitted" do
      datasets = for index <- 1..State.dataset_count_max(), do: :"dataset_#{index}"

      state = new(%{datasets: datasets})

      assert Enum.all?(datasets, &State.dataset?(state, &1))
    end

    test "raises for a dataset beyond the bound" do
      datasets = for index <- 1..(State.dataset_count_max() + 1), do: :"dataset_#{index}"

      assert_raise AssertionError, ~r/datasets/, fn -> new(%{datasets: datasets}) end
    end
  end

  describe "invalid input" do
    for settings <- [
          %{item_count_max: 0},
          %{holder_item_count_max: 0},
          %{datasets: []},
          %{datasets: [:arrivals, :arrivals]},
          %{datasets: ["arrivals"]}
        ] do
      test "raises for the settings #{inspect(settings)}" do
        assert_raise AssertionError, fn -> new(unquote(Macro.escape(settings))) end
      end
    end

    test "a dataset the state was not given is not admitted" do
      refute State.dataset?(new(), :routes)
    end

    test "raises for a registration in a dataset that is not admitted" do
      assert_raise AssertionError, ~r/dataset/, fn ->
        State.register(new(), %{holder: :a, key: {:routes, "1_100"}})
      end
    end

    test "raises for a registration of an empty item" do
      assert_raise AssertionError, ~r/item/, fn ->
        State.register(new(), %{holder: :a, key: {:arrivals, ""}})
      end
    end

    test "raises for the items of a dataset that is not admitted" do
      assert_raise AssertionError, ~r/dataset/, fn -> State.items(new(), :routes) end
    end

    test "raises for the holder count of a key in a dataset that is not admitted" do
      assert_raise AssertionError, ~r/dataset/, fn ->
        State.holder_count(new(), {:routes, "1_100"})
      end
    end
  end
end
