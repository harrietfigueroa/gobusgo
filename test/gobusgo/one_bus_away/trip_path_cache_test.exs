defmodule Gobusgo.OneBusAway.TripPathCacheTest do
  # Verifies the trip path cache's bound and order: the pure state is fed
  # keys and says which leave, and the process is filled past its bound and
  # read back, so a test names the count it puts and what it expects held.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.TripPathCache
  alias Gobusgo.OneBusAway.TripPathCache.State

  @service_date_ms 1_794_211_200_000

  defp key(index), do: {"trip_#{index}", @service_date_ms}

  describe "State.put/2" do
    test "evicts nothing while the state holds fewer keys than its bound" do
      state = State.new(%{trip_count_max: 3})

      {state, evicted} = State.put(state, key(1))
      {_state, evicted_second} = State.put(state, key(2))

      assert {evicted, evicted_second} == {[], []}
    end

    test "evicts the key put earliest once a key past the bound arrives" do
      state =
        Enum.reduce(1..3, State.new(%{trip_count_max: 3}), fn index, state ->
          {state, []} = State.put(state, key(index))
          state
        end)

      {state, evicted} = State.put(state, key(4))

      assert evicted == [key(1)]
      assert State.count(state) == 3
    end

    test "moves a key put again to the back without counting it twice" do
      state = State.new(%{trip_count_max: 2})
      {state, []} = State.put(state, key(1))
      {state, []} = State.put(state, key(2))
      {state, []} = State.put(state, key(1))

      {state, evicted} = State.put(state, key(3))

      assert evicted == [key(2)]
      assert State.count(state) == 2
    end
  end

  describe "the cache process" do
    setup context do
      cache = Module.concat(__MODULE__, "Cache#{context.line}")
      start_supervised!({TripPathCache, name: cache, trip_count_max: 2})
      %{cache: cache}
    end

    test "returns what was put under a key", %{cache: cache} do
      :ok = TripPathCache.put(cache, [{key(1), %{points: "path"}}])

      assert TripPathCache.lookup(cache, key(1)) == %{points: "path"}
    end

    test "returns nil for a key never put", %{cache: cache} do
      assert TripPathCache.lookup(cache, key(1)) == nil
    end

    test "holds no more trips than its bound", %{cache: cache} do
      entries = for index <- 1..3, do: {key(index), %{points: "path #{index}"}}

      :ok = TripPathCache.put(cache, entries)

      assert TripPathCache.count(cache) == 2
      assert TripPathCache.lookup(cache, key(1)) == nil
      assert TripPathCache.lookup(cache, key(3)) == %{points: "path 3"}
    end

    test "returns nil and a count of zero for a cache that is not running" do
      assert TripPathCache.lookup(NotRunning, key(1)) == nil
      assert TripPathCache.count(NotRunning) == 0
    end
  end
end
