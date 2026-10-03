defmodule Gobusgo.OneBusAway.RequestGate.StateTest do
  # Verifies the gate's rules as pure functions: every case supplies the
  # times and the jitter itself, so the bucket, the bounds, and the pause are
  # observed with no process and no clock.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.RequestGate.State

  @limits %{
    refill_interval_ms: 1_000,
    in_flight_count_max: 2,
    waiter_count_max: 2,
    pause_ms_base: 1_000,
    pause_ms_max: 8_000,
    retry_after_ms_max: 30_000
  }
  @far_deadline_ms 1_000_000

  defp new, do: State.new(@limits)

  defp enqueue!(state, id, deadline_at_ms \\ @far_deadline_ms) do
    {:ok, state} = State.enqueue(state, %{id: id, deadline_at_ms: deadline_at_ms})
    state
  end

  defp advance(state, now_ms) do
    {state, %{granted: granted, expired: expired}} = State.advance(state, now_ms)
    {state, granted, expired}
  end

  defp release(state, id, outcome, now_ms, jitter \\ 1.0) do
    State.release(state, %{id: id, outcome: outcome, now_ms: now_ms, jitter: jitter})
  end

  # Grants `id` at `now_ms` and returns the state holding it.
  defp grant!(state, id, now_ms) do
    {state, [^id], []} = state |> enqueue!(id) |> advance(now_ms)
    state
  end

  describe "the bucket" do
    test "grants the first waiter at once" do
      assert {_state, [:a], []} = new() |> enqueue!(:a) |> advance(0)
    end

    test "grants one waiter per refill interval, in arrival order" do
      state = new() |> enqueue!(:a) |> enqueue!(:b)

      assert {state, [:a], []} = advance(state, 0)
      assert {state, [], []} = advance(state, 999)
      assert {_state, [:b], []} = advance(state, 1_000)
    end

    test "holds no more than one token after an idle period" do
      state = new() |> enqueue!(:a) |> enqueue!(:b)

      assert {state, [:a], []} = advance(state, 50_000)
      assert {_state, [], []} = advance(state, 50_001)
    end
  end

  describe "the in-flight cap" do
    test "grants nothing while the cap is held, and grants again after a release" do
      state = new() |> grant!(:a, 0) |> grant!(:b, 1_000) |> enqueue!(:c)

      assert {state, [], []} = advance(state, 5_000)

      state = release(state, :a, :completed, 5_000)

      assert {_state, [:c], []} = advance(state, 5_000)
    end
  end

  describe "the waiter bound" do
    test "returns full for a waiter past the bound" do
      state = new() |> enqueue!(:a) |> enqueue!(:b)

      assert State.enqueue(state, %{id: :c, deadline_at_ms: @far_deadline_ms}) == :full
    end

    test "expires a waiter whose deadline has come" do
      state = new() |> grant!(:a, 0) |> enqueue!(:b, 500)

      assert {state, [], []} = advance(state, 499)
      assert {state, [], [:b]} = advance(state, 500)
      assert State.waiter_count(state) == 0
    end

    test "grants a waiter with no time left when a permit is free" do
      state = enqueue!(new(), :a, 0)

      assert {_state, [:a], []} = advance(state, 0)
    end

    test "forgets a waiter that is released before its grant" do
      state = new() |> grant!(:a, 0) |> enqueue!(:b)

      state = release(state, :b, :failed, 10)

      assert {_state, [], []} = advance(state, 1_000)
    end
  end

  describe "wake_at_ms/1" do
    test "is nil with no waiter" do
      assert State.wake_at_ms(new()) == nil
    end

    test "is the next token for a waiter the cap leaves room for" do
      state = new() |> grant!(:a, 0) |> enqueue!(:b)

      assert State.wake_at_ms(state) == 1_000
    end

    test "is the waiter's deadline when it comes before the next token" do
      state = new() |> grant!(:a, 0) |> enqueue!(:b, 400)

      assert State.wake_at_ms(state) == 400
    end

    test "is the end of the pause when that comes after the next token" do
      state = new() |> grant!(:a, 0) |> release(:a, {:rate_limited, 5_000}, 100) |> enqueue!(:b)

      assert State.wake_at_ms(state) == 5_100
    end

    test "is the earliest deadline while the cap is held" do
      state = new() |> grant!(:a, 0) |> grant!(:b, 1_000) |> enqueue!(:c, 9_000)

      assert State.wake_at_ms(state) == 9_000
    end
  end

  describe "a rate-limited response" do
    test "pauses every grant for the Retry-After time" do
      state = new() |> grant!(:a, 0) |> release(:a, {:rate_limited, 5_000}, 100) |> enqueue!(:b)

      assert {state, [], []} = advance(state, 5_099)
      assert {_state, [:b], []} = advance(state, 5_100)
    end

    test "bounds a Retry-After time by its maximum" do
      state = new() |> grant!(:a, 0) |> release(:a, {:rate_limited, 999_000}, 0) |> enqueue!(:b)

      assert State.wake_at_ms(state) == 30_000
    end

    for {name, jitter, pause_ms} <- [
          {"the whole window at full jitter", 1.0, 1_000},
          {"half the window at no jitter", 0.0, 500}
        ] do
      test "without Retry-After pauses for #{name}" do
        state =
          new()
          |> grant!(:a, 0)
          |> release(:a, {:rate_limited, nil}, 0, unquote(jitter))
          |> enqueue!(:b)

        assert State.wake_at_ms(state) == max(unquote(pause_ms), 1_000)
        assert State.mode(state) == {:paused, unquote(pause_ms)}
      end
    end

    test "doubles the pause on each rate-limited probe, up to the maximum" do
      state = new() |> grant!(:a, 0) |> release(:a, {:rate_limited, nil}, 0)

      {_state, pauses} =
        Enum.reduce(1..5, {state, []}, fn index, {state, pauses} ->
          {:paused, until_ms} = State.mode(state)

          state =
            state |> grant!(index, until_ms) |> release(index, {:rate_limited, nil}, until_ms)

          {:paused, next_until_ms} = State.mode(state)
          {state, pauses ++ [next_until_ms - until_ms]}
        end)

      assert pauses == [2_000, 4_000, 8_000, 8_000, 8_000]
    end
  end

  describe "the probe after a pause" do
    defp paused do
      new() |> grant!(:a, 0) |> release(:a, {:rate_limited, 2_000}, 0)
    end

    test "is the only grant until it finishes" do
      state = paused() |> enqueue!(:b) |> enqueue!(:c)

      assert {state, [:b], []} = advance(state, 2_000)
      assert State.mode(state) == {:probing, :b}
      assert {_state, [], []} = advance(state, 10_000)
    end

    test "reopens the gate when it completes" do
      state = paused() |> grant!(:b, 2_000) |> release(:b, :completed, 2_100) |> enqueue!(:c)

      assert State.mode(state) == :open
      assert {_state, [:c], []} = advance(state, 3_000)
    end

    test "restarts the backoff once the gate has reopened" do
      state =
        new()
        |> grant!(:a, 0)
        |> release(:a, {:rate_limited, nil}, 0)
        |> grant!(:b, 1_000)
        |> release(:b, :completed, 1_100)
        |> grant!(:c, 2_000)
        |> release(:c, {:rate_limited, nil}, 2_000)

      assert State.mode(state) == {:paused, 3_000}
    end

    test "lets the next waiter probe when it fails without a response" do
      state = paused() |> grant!(:b, 2_000) |> release(:b, :failed, 2_100) |> enqueue!(:c)

      assert {state, [:c], []} = advance(state, 3_000)
      assert State.mode(state) == {:probing, :c}
    end

    test "stays paused when a request granted before the pause completes" do
      state =
        new()
        |> grant!(:a, 0)
        |> grant!(:b, 1_000)
        |> release(:a, {:rate_limited, 5_000}, 1_100)
        |> release(:b, :completed, 1_200)

      assert State.mode(state) == {:paused, 6_100}
    end
  end

  describe "assertions" do
    test "new/1 raises for a limit that is not positive" do
      assert_raise AssertionError, ~r/waiter_count_max/, fn ->
        State.new(%{@limits | waiter_count_max: 0})
      end
    end

    test "enqueue/2 raises for an identifier already known" do
      state = enqueue!(new(), :a)

      assert_raise AssertionError, ~r/identifier/, fn -> enqueue!(state, :a) end
    end

    test "release/2 raises for a jitter outside zero to one" do
      state = grant!(new(), :a, 0)

      assert_raise AssertionError, ~r/jitter/, fn ->
        release(state, :a, {:rate_limited, nil}, 0, 1.5)
      end
    end
  end
end
