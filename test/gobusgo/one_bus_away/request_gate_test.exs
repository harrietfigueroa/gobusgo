defmodule Gobusgo.OneBusAway.RequestGateTest do
  # Verifies the gate process against real time with intervals of tens of
  # milliseconds: callers are test processes and tasks, and each case
  # observes only what acquire/2 returns and when. The exact timing rules are
  # covered without a clock in the state tests.
  use ExUnit.Case, async: true

  @moduletag capture_log: true

  alias Gobusgo.OneBusAway.RequestGate

  @wait_ms 2_000

  defp start_gate(limits) do
    options =
      Keyword.merge(
        [name: nil, refill_interval_ms: 1, in_flight_count_max: 4, waiter_count_max: 4],
        limits
      )

    start_supervised!({RequestGate, options})
  end

  defp elapsed_ms(function) do
    started_at_ms = System.monotonic_time(:millisecond)
    result = function.()
    {result, System.monotonic_time(:millisecond) - started_at_ms}
  end

  defp release(gate, permit, outcome) do
    RequestGate.release(gate, %{permit: permit, outcome: outcome})
  end

  describe "the bucket" do
    test "grants the first permit at once and the second a refill interval later" do
      gate = start_gate(refill_interval_ms: 80)

      assert {{:ok, _permit}, first_ms} =
               elapsed_ms(fn -> RequestGate.acquire(gate, @wait_ms) end)

      assert {{:ok, _permit}, second_ms} =
               elapsed_ms(fn -> RequestGate.acquire(gate, @wait_ms) end)

      assert first_ms < 40
      assert second_ms >= 70
    end
  end

  describe "the in-flight cap" do
    test "holds a caller until a permit is released" do
      gate = start_gate(in_flight_count_max: 1)
      {:ok, permit} = RequestGate.acquire(gate, @wait_ms)

      waiter = Task.async(fn -> RequestGate.acquire(gate, @wait_ms) end)
      assert Task.yield(waiter, 50) == nil

      release(gate, permit, :completed)
      assert {:ok, _permit} = Task.await(waiter)
    end
  end

  describe "the waiter bounds" do
    test "returns rate_limited at once to a caller past the waiter bound" do
      gate = start_gate(in_flight_count_max: 1, waiter_count_max: 1)
      {:ok, _permit} = RequestGate.acquire(gate, @wait_ms)
      _waiter = Task.async(fn -> RequestGate.acquire(gate, @wait_ms) end)
      Process.sleep(20)

      assert {{:error, :rate_limited}, elapsed_ms} =
               elapsed_ms(fn -> RequestGate.acquire(gate, @wait_ms) end)

      assert elapsed_ms < 100
    end

    test "returns rate_limited to a waiter when its wait runs out" do
      gate = start_gate(in_flight_count_max: 1)
      {:ok, _permit} = RequestGate.acquire(gate, @wait_ms)

      assert {{:error, :rate_limited}, elapsed_ms} =
               elapsed_ms(fn -> RequestGate.acquire(gate, 60) end)

      assert elapsed_ms >= 50
      assert elapsed_ms < 500
    end
  end

  describe "a rate-limited response" do
    test "pauses every caller for the time the response names" do
      gate = start_gate([])
      {:ok, permit} = RequestGate.acquire(gate, @wait_ms)
      release(gate, permit, {:rate_limited, 150})

      assert RequestGate.acquire(gate, 30) == {:error, :rate_limited}

      assert {{:ok, _permit}, elapsed_ms} =
               elapsed_ms(fn -> RequestGate.acquire(gate, @wait_ms) end)

      assert elapsed_ms >= 60
    end

    test "grants one probe after the pause and reopens when it completes" do
      gate = start_gate([])
      {:ok, permit} = RequestGate.acquire(gate, @wait_ms)
      release(gate, permit, {:rate_limited, 20})
      {:ok, probe} = RequestGate.acquire(gate, @wait_ms)

      assert RequestGate.acquire(gate, 40) == {:error, :rate_limited}

      release(gate, probe, :completed)
      assert {:ok, _permit} = RequestGate.acquire(gate, @wait_ms)
      assert {:ok, _permit} = RequestGate.acquire(gate, @wait_ms)
    end

    test "pauses without a named time, inside the backoff window" do
      gate = start_gate(pause_ms_base: 100, pause_ms_max: 100)
      {:ok, permit} = RequestGate.acquire(gate, @wait_ms)
      release(gate, permit, {:rate_limited, nil})

      assert {{:ok, _permit}, elapsed_ms} =
               elapsed_ms(fn -> RequestGate.acquire(gate, @wait_ms) end)

      assert elapsed_ms >= 40
      assert elapsed_ms < 500
    end
  end

  describe "a caller that exits" do
    test "frees its permit" do
      gate = start_gate(in_flight_count_max: 1)

      {holder, monitor} =
        spawn_monitor(fn ->
          {:ok, _permit} = RequestGate.acquire(gate, @wait_ms)
        end)

      assert_receive {:DOWN, ^monitor, :process, ^holder, :normal}
      assert {:ok, _permit} = RequestGate.acquire(gate, @wait_ms)
    end

    test "frees its permit when it is killed" do
      gate = start_gate(in_flight_count_max: 1)
      test_pid = self()

      holder =
        spawn(fn ->
          {:ok, _permit} = RequestGate.acquire(gate, @wait_ms)
          send(test_pid, :holding)
          Process.sleep(:infinity)
        end)

      assert_receive :holding
      Process.exit(holder, :kill)

      assert {:ok, _permit} = RequestGate.acquire(gate, @wait_ms)
    end

    test "gives up its place among the waiters" do
      gate = start_gate(in_flight_count_max: 1, waiter_count_max: 1)
      {:ok, permit} = RequestGate.acquire(gate, @wait_ms)
      waiter = spawn(fn -> RequestGate.acquire(gate, @wait_ms) end)
      Process.sleep(20)
      Process.exit(waiter, :kill)
      Process.sleep(20)

      next = Task.async(fn -> RequestGate.acquire(gate, @wait_ms) end)
      assert Task.yield(next, 50) == nil

      release(gate, permit, :completed)
      assert {:ok, _permit} = Task.await(next)
    end

    test "lets the next caller probe when the probe's holder is killed" do
      gate = start_gate([])
      {:ok, permit} = RequestGate.acquire(gate, @wait_ms)
      release(gate, permit, {:rate_limited, 10})
      test_pid = self()

      prober =
        spawn(fn ->
          {:ok, _permit} = RequestGate.acquire(gate, @wait_ms)
          send(test_pid, :probing)
          Process.sleep(:infinity)
        end)

      assert_receive :probing
      Process.exit(prober, :kill)

      assert {:ok, _permit} = RequestGate.acquire(gate, @wait_ms)
    end
  end

  describe "release/2" do
    test "ignores a permit that was released already" do
      gate = start_gate(in_flight_count_max: 1)
      {:ok, permit} = RequestGate.acquire(gate, @wait_ms)

      assert release(gate, permit, :completed) == :ok
      assert release(gate, permit, {:rate_limited, 5_000}) == :ok
      assert {:ok, _permit} = RequestGate.acquire(gate, @wait_ms)
    end
  end
end
