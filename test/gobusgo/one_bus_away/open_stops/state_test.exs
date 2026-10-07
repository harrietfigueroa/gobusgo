defmodule Gobusgo.OneBusAway.OpenStops.StateTest do
  # Verifies the rules of the open stops as pure functions: each case opens
  # and closes stops for openers that are plain atoms and reads the outcome
  # and the open stops.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.OpenStops.State

  defp new(bounds \\ %{}) do
    State.new(Map.merge(%{stop_count_max: 3, opener_stop_count_max: 2}, bounds))
  end

  defp open_all(state, openings) do
    Enum.reduce(openings, state, fn {opener, stop_id}, state ->
      {state, :opened} = State.open(state, %{opener: opener, stop_id: stop_id})
      state
    end)
  end

  test "no stop is open at first" do
    assert State.stop_ids(new()) == []
  end

  test "a stop an opener opens is open" do
    assert {state, :opened} = State.open(new(), %{opener: :a, stop_id: "1_100"})
    assert State.stop_ids(state) == ["1_100"]
  end

  test "the open stops are sorted and each named once" do
    state = open_all(new(), [{:a, "1_300"}, {:b, "1_100"}, {:c, "1_300"}])

    assert State.stop_ids(state) == ["1_100", "1_300"]
  end

  test "opening a stop the opener has open changes nothing" do
    state = open_all(new(), [{:a, "1_100"}])

    assert State.open(state, %{opener: :a, stop_id: "1_100"}) == {state, :already_open}
  end

  test "a stop stays open while another opener has it open" do
    state = open_all(new(), [{:a, "1_100"}, {:b, "1_100"}])

    state = State.close(state, %{opener: :a, stop_id: "1_100"})

    assert State.stop_ids(state) == ["1_100"]
  end

  test "a stop its last opener closes is closed" do
    state = open_all(new(), [{:a, "1_100"}])

    state = State.close(state, %{opener: :a, stop_id: "1_100"})

    assert state == new()
  end

  test "closing a stop the opener has not open changes nothing" do
    state = open_all(new(), [{:a, "1_100"}])

    assert State.close(state, %{opener: :b, stop_id: "1_100"}) == state
    assert State.close(state, %{opener: :a, stop_id: "1_999"}) == state
  end

  test "closing every stop of an opener leaves the stops of the others" do
    state = open_all(new(), [{:a, "1_100"}, {:a, "1_200"}, {:b, "1_200"}])

    state = State.close_all(state, :a)

    assert State.stop_ids(state) == ["1_200"]
    refute State.opener?(state, :a)
    assert State.opener?(state, :b)
  end

  test "closing every stop of an opener that has none changes nothing" do
    state = open_all(new(), [{:a, "1_100"}])

    assert State.close_all(state, :b) == state
  end

  describe "bounds" do
    test "as many stops open as the bound allows" do
      state = open_all(new(), [{:a, "1_1"}, {:b, "1_2"}, {:c, "1_3"}])

      assert State.stop_ids(state) == ["1_1", "1_2", "1_3"]
    end

    test "a stop beyond the bound is refused" do
      state = open_all(new(), [{:a, "1_1"}, {:b, "1_2"}, {:c, "1_3"}])

      assert State.open(state, %{opener: :d, stop_id: "1_4"}) == {state, :stop_count_exceeded}
    end

    test "a stop that is open already is opened at the bound" do
      state = open_all(new(), [{:a, "1_1"}, {:b, "1_2"}, {:c, "1_3"}])

      assert {_state, :opened} = State.open(state, %{opener: :d, stop_id: "1_3"})
    end

    test "a closed stop leaves its place to another" do
      state = open_all(new(), [{:a, "1_1"}, {:b, "1_2"}, {:c, "1_3"}])
      state = State.close(state, %{opener: :a, stop_id: "1_1"})

      assert {_state, :opened} = State.open(state, %{opener: :d, stop_id: "1_4"})
    end

    test "an opener's stop beyond its own bound is refused" do
      state = open_all(new(), [{:a, "1_1"}, {:a, "1_2"}])

      assert State.open(state, %{opener: :a, stop_id: "1_3"}) ==
               {state, :opener_stop_count_exceeded}
    end

    for bounds <- [
          %{stop_count_max: 0, opener_stop_count_max: 1},
          %{stop_count_max: 1, opener_stop_count_max: 0}
        ] do
      test "raises for the bounds #{inspect(bounds)}" do
        assert_raise AssertionError, fn -> State.new(unquote(Macro.escape(bounds))) end
      end
    end
  end
end
