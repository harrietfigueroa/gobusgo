defmodule Gobusgo.OneBusAway.FetchView.StateTest do
  # Verifies the rules of a fetch view as pure functions: each case puts
  # fetches into a state and reads the outcome and the current headers.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.FetchView.State

  @first_request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @second_request_id "0199c4a2-7e1b-7a3f-9d20-000000000002"
  @earlier ~U[2026-10-05 01:00:00Z]
  @later ~U[2026-10-05 02:00:00Z]

  defp fetch(overrides) do
    Map.merge(%{id: "40", request_id: @first_request_id, fetched_at: @earlier}, overrides)
  end

  defp put_all(fetches, id_count_max \\ 8) do
    Enum.reduce(fetches, {State.new(id_count_max), []}, fn fetch, {state, outcomes} ->
      {state, outcome} = State.put(state, fetch)
      {state, outcomes ++ [outcome]}
    end)
  end

  test "a new view has no current fetch" do
    assert State.current(State.new(8)) == %{}
  end

  test "the first fetch of an identifier becomes its current fetch" do
    {state, outcomes} = put_all([fetch(%{})])

    assert outcomes == [:switched]

    assert State.current(state) == %{
             "40" => %{request_id: @first_request_id, fetched_at: @earlier}
           }
  end

  test "a newer fetch replaces the current one" do
    {state, outcomes} =
      put_all([fetch(%{}), fetch(%{request_id: @second_request_id, fetched_at: @later})])

    assert outcomes == [:switched, :switched]
    assert %{"40" => %{request_id: @second_request_id, fetched_at: @later}} = State.current(state)
  end

  test "an older fetch is ignored" do
    {state, outcomes} =
      put_all([
        fetch(%{request_id: @second_request_id, fetched_at: @later}),
        fetch(%{})
      ])

    assert outcomes == [:switched, :ignored]
    assert %{"40" => %{request_id: @second_request_id}} = State.current(state)
  end

  test "the current fetch put again is ignored" do
    {_state, outcomes} = put_all([fetch(%{}), fetch(%{})])

    assert outcomes == [:switched, :ignored]
  end

  test "a fetch made at the same time under another request replaces the current one" do
    {state, outcomes} = put_all([fetch(%{}), fetch(%{request_id: @second_request_id})])

    assert outcomes == [:switched, :switched]
    assert %{"40" => %{request_id: @second_request_id}} = State.current(state)
  end

  test "the fetch of one identifier leaves another's as it is" do
    {state, outcomes} =
      put_all([fetch(%{}), fetch(%{id: "1", request_id: @second_request_id, fetched_at: @later})])

    assert outcomes == [:switched, :switched]
    assert %{"40" => %{request_id: @first_request_id}, "1" => %{}} = State.current(state)
  end

  test "the fetch of an identifier beyond the bound is ignored" do
    {state, outcomes} = put_all([fetch(%{id: "1"}), fetch(%{id: "2"}), fetch(%{id: "3"})], 2)

    assert outcomes == [:switched, :switched, :ignored]
    assert state |> State.current() |> Map.keys() == ["1", "2"]
  end

  test "an identifier within the bound still takes a newer fetch when the view is full" do
    {_state, outcomes} =
      put_all([fetch(%{id: "1"}), fetch(%{id: "1", request_id: @second_request_id})], 1)

    assert outcomes == [:switched, :switched]
  end

  test "raises for a bound below one" do
    assert_raise AssertionError, ~r/id_count_max/, fn -> State.new(0) end
  end

  describe "a view whose fetches expire" do
    @age_ms_max 60_000

    defp expiring(fetches) do
      state = State.new_expiring(%{id_count_max: 2, fetch_age_ms_max: @age_ms_max})

      Enum.reduce(fetches, state, fn fetch, state ->
        {state, _outcome} = State.put(state, fetch)
        state
      end)
    end

    test "keeps a fetch that is as old as the bound" do
      state = expiring([fetch(%{})])

      assert {state, []} = State.expire(state, DateTime.add(@earlier, @age_ms_max, :millisecond))
      assert Map.keys(State.current(state)) == ["40"]
    end

    test "removes the fetches older than the bound and names them, sorted" do
      state = expiring([fetch(%{id: "b"}), fetch(%{id: "a"})])
      now = DateTime.add(@earlier, @age_ms_max + 1, :millisecond)

      assert {state, ["a", "b"]} = State.expire(state, now)
      assert State.current(state) == %{}
    end

    test "keeps the fetches the bound has not reached" do
      state = expiring([fetch(%{id: "old"}), fetch(%{id: "new", fetched_at: @later})])

      assert {state, ["old"]} = State.expire(state, DateTime.add(@later, 1, :second))
      assert Map.keys(State.current(state)) == ["new"]
    end

    test "ignores a fetch that had expired at the last expiry" do
      {state, []} = State.expire(expiring([]), @later)

      assert State.put(state, fetch(%{})) == {state, :ignored}
    end

    test "takes a fetch into the place an expired one left" do
      state = expiring([fetch(%{id: "a"}), fetch(%{id: "b"})])
      {state, ["a", "b"]} = State.expire(state, @later)

      assert {_state, :switched} = State.put(state, fetch(%{id: "c", fetched_at: @later}))
    end

    test "raises for an age bound that is not positive" do
      assert_raise AssertionError, ~r/fetch_age_ms_max/, fn ->
        State.new_expiring(%{id_count_max: 2, fetch_age_ms_max: 0})
      end
    end
  end

  # An attempt is a fetch that was recorded; the view keeps its time until a
  # fetch at least that late reaches it.
  describe "attempts" do
    test "a view starts with none" do
      assert State.attempts(State.new(8)) == %{}
    end

    test "an attempt of an identifier with no fetch is kept with its time" do
      state = State.attempt(State.new(8), %{id: "40", fetched_at: @earlier})

      assert State.attempts(state) == %{"40" => @earlier}
      assert State.current(state) == %{}
    end

    test "a later attempt replaces an earlier one" do
      state = State.attempt(State.new(8), %{id: "40", fetched_at: @earlier})
      state = State.attempt(state, %{id: "40", fetched_at: @later})

      assert State.attempts(state) == %{"40" => @later}
    end

    test "an earlier attempt changes nothing" do
      state = State.attempt(State.new(8), %{id: "40", fetched_at: @later})

      assert State.attempt(state, %{id: "40", fetched_at: @earlier}) == state
    end

    test "an attempt made after the current fetch is kept beside it" do
      {state, [:switched]} = put_all([fetch(%{})])
      state = State.attempt(state, %{id: "40", fetched_at: @later})

      assert State.attempts(state) == %{"40" => @later}
      assert Map.keys(State.current(state)) == ["40"]
    end

    test "an attempt no later than the current fetch changes nothing" do
      {state, [:switched]} = put_all([fetch(%{fetched_at: @later})])

      assert State.attempt(state, %{id: "40", fetched_at: @later}) == state
    end

    test "a fetch put at or after an attempt clears it" do
      state = State.attempt(State.new(8), %{id: "40", fetched_at: @earlier})

      assert {state, :switched} = State.put(state, fetch(%{fetched_at: @earlier}))
      assert State.attempts(state) == %{}
    end

    test "the earliest attempt leaves when the bound is reached" do
      state = State.attempt(State.new(2), %{id: "a", fetched_at: @later})
      state = State.attempt(state, %{id: "b", fetched_at: @earlier})
      state = State.attempt(state, %{id: "c", fetched_at: @later})

      assert State.attempts(state) == %{"a" => @later, "c" => @later}
    end

    test "expiry removes an attempt older than the bound" do
      state = State.new_expiring(%{id_count_max: 2, fetch_age_ms_max: 60_000})
      state = State.attempt(state, %{id: "old", fetched_at: @earlier})
      state = State.attempt(state, %{id: "new", fetched_at: @later})

      assert {state, []} = State.expire(state, DateTime.add(@later, 1, :second))
      assert State.attempts(state) == %{"new" => @later}
    end
  end

  test "a view whose fetches do not expire removes none" do
    {state, [:switched]} = put_all([fetch(%{})])

    assert State.expire(state, DateTime.add(@later, 365, :day)) == {state, []}
  end
end
