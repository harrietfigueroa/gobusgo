defmodule Gobusgo.CadenceTest do
  # Calls the pure cadence functions with policies, signals, and bounds the
  # test names, with no process and no timer, and reads what they return.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Cadence

  @bounds %{interval_ms_min: 5_000, interval_ms_max: 60_000}

  describe "interval_ms/2" do
    for interval_ms <- [1, 5_000, 60_000] do
      test "returns the #{interval_ms} ms of a fixed policy" do
        assert Cadence.interval_ms({:fixed, unquote(interval_ms)}, %{}) == unquote(interval_ms)
      end
    end

    for signals <- [%{}, %{viewer_count: 3}, %{item_count: 0, unknown: "value"}] do
      test "ignores the signals #{inspect(signals)} under a fixed policy" do
        assert Cadence.interval_ms({:fixed, 5_000}, unquote(Macro.escape(signals))) == 5_000
      end
    end

    for signals <- [nil, [], [viewer_count: 3], 5_000] do
      test "refuses the signals #{inspect(signals)}, which are not a map" do
        assert_raise AssertionError, fn ->
          Cadence.interval_ms({:fixed, 5_000}, unquote(signals))
        end
      end
    end

    for policy <- [{:fixed, 0}, {:fixed, -1}, {:fixed, 1.5}, {:fixed, nil}] do
      test "refuses the policy #{inspect(policy)}, whose interval is not a positive integer" do
        assert_raise AssertionError, fn -> Cadence.interval_ms(unquote(policy), %{}) end
      end
    end

    for policy <- [:fixed, 5_000, {:unknown, 5_000}, {:fixed, 5_000, 60_000}, nil] do
      test "refuses the unknown policy shape #{inspect(policy)}" do
        assert_raise AssertionError, fn ->
          Cadence.interval_ms(unquote(Macro.escape(policy)), %{})
        end
      end
    end
  end

  describe "interval_ms_min/1" do
    test "is the one interval of a fixed policy" do
      assert Cadence.interval_ms_min({:fixed, 5_000}) == 5_000
    end

    test "refuses an unknown policy shape" do
      assert_raise AssertionError, fn -> Cadence.interval_ms_min({:unknown, 5_000}) end
    end
  end

  describe "assert_policy/1" do
    test "accepts a fixed policy with a positive integer interval" do
      assert Cadence.assert_policy({:fixed, 5_000}) == :ok
    end

    test "refuses a fixed policy whose interval is zero" do
      assert_raise AssertionError, fn -> Cadence.assert_policy({:fixed, 0}) end
    end

    test "refuses an unknown policy shape" do
      assert_raise AssertionError, fn -> Cadence.assert_policy({:unknown, 5_000}) end
    end
  end

  describe "assert_bounds/1" do
    for {interval_ms_min, interval_ms_max} <- [{1, 1}, {5_000, 5_000}, {5_000, 60_000}] do
      test "accepts a shortest interval of #{interval_ms_min} under a longest of #{interval_ms_max}" do
        bounds = %{
          interval_ms_min: unquote(interval_ms_min),
          interval_ms_max: unquote(interval_ms_max)
        }

        assert Cadence.assert_bounds(bounds) == :ok
      end
    end

    test "accepts bounds that travel in a map with other keys" do
      assert Cadence.assert_bounds(Map.put(@bounds, :spacing_ms, 5_000)) == :ok
    end

    test "refuses a shortest interval over the longest" do
      assert_raise AssertionError, fn ->
        Cadence.assert_bounds(%{interval_ms_min: 60_001, interval_ms_max: 60_000})
      end
    end

    for {field, value} <- [
          interval_ms_min: 0,
          interval_ms_min: 1.5,
          interval_ms_min: nil,
          interval_ms_max: 0,
          interval_ms_max: 60_000.0
        ] do
      test "refuses bounds whose #{field} is #{inspect(value)}" do
        bounds = Map.put(@bounds, unquote(field), unquote(value))

        assert_raise AssertionError, fn -> Cadence.assert_bounds(bounds) end
      end
    end

    for field <- [:interval_ms_min, :interval_ms_max] do
      test "refuses bounds without #{field}" do
        bounds = Map.delete(@bounds, unquote(field))

        assert_raise AssertionError, fn -> Cadence.assert_bounds(bounds) end
      end
    end
  end

  describe "clamp/2" do
    # Each row is a computed interval and the interval the bounds of 5,000
    # to 60,000 ms allow for it: one row at each bound, one a millisecond
    # past each, one far past each, and one between them.
    for {label, computed_ms, clamped_ms} <- [
          {"at the shortest", 5_000, 5_000},
          {"one millisecond under the shortest", 4_999, 5_000},
          {"of zero", 0, 5_000},
          {"under zero", -30_000, 5_000},
          {"at the longest", 60_000, 60_000},
          {"one millisecond over the longest", 60_001, 60_000},
          {"far over the longest", 86_400_000, 60_000},
          {"between the bounds", 12_345, 12_345}
        ] do
      test "returns #{clamped_ms} for a computed interval #{label}" do
        assert Cadence.clamp(unquote(computed_ms), @bounds) == unquote(clamped_ms)
      end
    end

    test "returns the one interval that equal bounds allow" do
      bounds = %{interval_ms_min: 5_000, interval_ms_max: 5_000}

      assert Enum.map([4_999, 5_000, 5_001], &Cadence.clamp(&1, bounds)) == [5_000, 5_000, 5_000]
    end

    for computed_ms <- [5_000.0, nil, :infinity] do
      test "refuses the computed interval #{inspect(computed_ms)}, which is not an integer" do
        assert_raise AssertionError, fn -> Cadence.clamp(unquote(computed_ms), @bounds) end
      end
    end

    test "refuses bounds whose shortest interval is over the longest" do
      assert_raise AssertionError, fn ->
        Cadence.clamp(5_000, %{interval_ms_min: 60_001, interval_ms_max: 60_000})
      end
    end
  end
end
