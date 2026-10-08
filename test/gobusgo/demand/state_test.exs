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

    state = State.release(state, %{holder: :a, key: {:arrivals, "1_100"}, now_ms: 0})

    assert State.items(state, :arrivals) == ["1_100"]
  end

  test "an item whose last holder releases its key is gone" do
    state = register_all(new(), [{:a, {:arrivals, "1_100"}}])

    state = State.release(state, %{holder: :a, key: {:arrivals, "1_100"}, now_ms: 0})

    assert State.items(state, :arrivals) == []
  end

  for {name, registration} <- [
        {"another holder", %{holder: :b, key: {:arrivals, "1_100"}, now_ms: 0}},
        {"another item", %{holder: :a, key: {:arrivals, "1_999"}, now_ms: 0}},
        {"another dataset", %{holder: :a, key: {:vehicles, "1_100"}, now_ms: 0}}
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

    state = State.release_all(state, %{holder: :a, now_ms: 0})

    assert State.items(state, :arrivals) == ["1_200"]
    assert State.items(state, :vehicles) == []
    refute State.holder?(state, :a)
    assert State.holder?(state, :b)
  end

  test "releasing every key of a holder that has none changes nothing" do
    state = register_all(new(), [{:a, {:arrivals, "1_100"}}])

    assert State.release_all(state, %{holder: :b, now_ms: 0}) == state
  end

  test "a holder of a key in any dataset is a holder" do
    state = register_all(new(), [{:a, {:vehicles, "all"}}])

    assert State.holder?(state, :a)
  end

  describe "holding/2" do
    @vehicles {:vehicles, "all"}

    test "is no holder and no absence for a key nobody has held" do
      assert State.holding(new(), %{key: @vehicles, now_ms: 500}) ==
               %{holder_count: 0, holder_absence_ms: nil}
    end

    test "is the count of holders and an absence of zero while the key is held" do
      state = register_all(new(), [{:a, @vehicles}, {:b, @vehicles}])

      assert State.holding(state, %{key: @vehicles, now_ms: 500}) ==
               %{holder_count: 2, holder_absence_ms: 0}
    end

    test "counts the absence from the time the last holder released the key" do
      state = register_all(new(), [{:a, @vehicles}, {:b, @vehicles}])
      state = State.release(state, %{holder: :a, key: @vehicles, now_ms: 100})
      state = State.release(state, %{holder: :b, key: @vehicles, now_ms: 300})

      assert State.holding(state, %{key: @vehicles, now_ms: 1_000}) ==
               %{holder_count: 0, holder_absence_ms: 700}
    end

    test "counts the absence from the time the last holder's every key was released" do
      state = register_all(new(), [{:a, @vehicles}])
      state = State.release_all(state, %{holder: :a, now_ms: 300})

      assert State.holding(state, %{key: @vehicles, now_ms: 1_000}) ==
               %{holder_count: 0, holder_absence_ms: 700}
    end

    test "keeps the absence as it is when a key nobody holds is released again" do
      state = register_all(new(), [{:a, @vehicles}])
      state = State.release(state, %{holder: :a, key: @vehicles, now_ms: 300})
      state = State.release(state, %{holder: :a, key: @vehicles, now_ms: 900})

      assert %{holder_absence_ms: 700} = State.holding(state, %{key: @vehicles, now_ms: 1_000})
    end

    test "is an absence of zero again once the key is held again" do
      state = register_all(new(), [{:a, @vehicles}])
      state = State.release(state, %{holder: :a, key: @vehicles, now_ms: 300})
      state = register_all(state, [{:b, @vehicles}])

      assert State.holding(state, %{key: @vehicles, now_ms: 1_000}) ==
               %{holder_count: 1, holder_absence_ms: 0}
    end

    # The dataset takes three items, so it remembers three releases: a
    # fourth takes the place of the one longest ago.
    test "forgets the release longest ago beyond the count of items of the dataset" do
      state =
        Enum.reduce(1..4, new(), fn index, state ->
          key = {:arrivals, "1_#{index}"}
          state = register_all(state, [{:a, key}])
          State.release(state, %{holder: :a, key: key, now_ms: index * 100})
        end)

      assert %{holder_absence_ms: nil} =
               State.holding(state, %{key: {:arrivals, "1_1"}, now_ms: 1_000})

      assert %{holder_absence_ms: 800} =
               State.holding(state, %{key: {:arrivals, "1_2"}, now_ms: 1_000})
    end

    test "raises for a time before the release it is counted from" do
      state = register_all(new(), [{:a, @vehicles}])
      state = State.release(state, %{holder: :a, key: @vehicles, now_ms: 300})

      assert_raise AssertionError, ~r/time/, fn ->
        State.holding(state, %{key: @vehicles, now_ms: 299})
      end
    end
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

      state = State.release(state, %{holder: :a, key: {:vehicles, "all"}, now_ms: 0})

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
      state = State.release(state, %{holder: :a, key: {:arrivals, "1_1"}, now_ms: 0})

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
