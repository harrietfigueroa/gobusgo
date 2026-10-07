defmodule Gobusgo.CadenceTest do
  # Calls the pure cadence functions with policies, signals, and bounds the
  # test names, with no process and no timer, and reads what they return.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Cadence

  @bounds %{interval_ms_min: 5_000, interval_ms_max: 60_000}
  @proportional {:proportional,
                 %{interval_ms_min: 30_000, interval_ms_max: 300_000, item_spacing_ms: 5_000}}

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

  describe "interval_ms/2 under a proportional policy" do
    # Each row is a count of items and the interval that a spacing of
    # 5,000 ms an item decides for it between 30,000 and 300,000 ms: no
    # item, the counts on each side of where the product leaves the shortest
    # interval and of where it reaches the longest, one between them, and
    # one far past any count a caller holds.
    for {item_count, interval_ms} <- [
          {0, 30_000},
          {1, 30_000},
          {6, 30_000},
          {7, 35_000},
          {12, 60_000},
          {59, 295_000},
          {60, 300_000},
          {61, 300_000},
          {10 ** 30, 300_000}
        ] do
      test "returns #{interval_ms} ms for #{item_count} items" do
        signals = %{item_count: unquote(item_count)}

        assert Cadence.interval_ms(@proportional, signals) == unquote(interval_ms)
      end
    end

    test "reads the item count beside signals it does not know" do
      assert Cadence.interval_ms(@proportional, %{item_count: 12, viewer_count: 3}) == 60_000
    end

    for item_count <- [-1, 1.5, 6.0, nil, "6"] do
      test "refuses the item count #{inspect(item_count)}, which is not a count" do
        assert_raise AssertionError, ~r/item_count/, fn ->
          Cadence.interval_ms(@proportional, %{item_count: unquote(item_count)})
        end
      end
    end

    test "refuses signals without an item count" do
      assert_raise AssertionError, ~r/item_count/, fn ->
        Cadence.interval_ms(@proportional, %{viewer_count: 3})
      end
    end
  end

  describe "interval_ms_min/1" do
    test "is the one interval of a fixed policy" do
      assert Cadence.interval_ms_min({:fixed, 5_000}) == 5_000
    end

    test "is the shortest interval of a proportional policy" do
      assert Cadence.interval_ms_min(@proportional) == 30_000
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

    test "accepts a proportional policy with bounds and a spacing" do
      assert Cadence.assert_policy(@proportional) == :ok
    end

    test "accepts a proportional policy whose bounds are equal" do
      policy =
        {:proportional, %{interval_ms_min: 30_000, interval_ms_max: 30_000, item_spacing_ms: 1}}

      assert Cadence.assert_policy(policy) == :ok
    end

    for {label, changes} <- [
          {"shortest interval is over its longest", %{interval_ms_min: 300_001}},
          {"shortest interval is zero", %{interval_ms_min: 0}},
          {"longest interval is not an integer", %{interval_ms_max: 300_000.0}},
          {"spacing is zero", %{item_spacing_ms: 0}},
          {"spacing is negative", %{item_spacing_ms: -5_000}},
          {"spacing is not an integer", %{item_spacing_ms: 5_000.0}}
        ] do
      test "refuses a proportional policy whose #{label}" do
        {:proportional, parameters} = @proportional
        policy = {:proportional, Map.merge(parameters, unquote(Macro.escape(changes)))}

        assert_raise AssertionError, fn -> Cadence.assert_policy(policy) end
      end
    end

    for field <- [:interval_ms_min, :interval_ms_max, :item_spacing_ms] do
      test "refuses a proportional policy without #{field}" do
        {:proportional, parameters} = @proportional
        policy = {:proportional, Map.delete(parameters, unquote(field))}

        assert_raise AssertionError, fn -> Cadence.assert_policy(policy) end
      end
    end

    test "refuses a proportional policy whose parameters are not a map" do
      assert_raise AssertionError, fn -> Cadence.assert_policy({:proportional, 5_000}) end
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

  # The step policy the vehicle source's shape has: 60 s with no viewer,
  # 5 s with one or more, held for 60 s after the last one leaves.
  @steps %{
    interval_ms_min: 5_000,
    interval_ms_max: 60_000,
    steps: [
      %{viewer_count_min: 0, interval_ms: 60_000},
      %{viewer_count_min: 1, interval_ms: 5_000}
    ],
    hold_ms: 60_000
  }

  defp steps(overrides \\ %{}), do: {:steps, Map.merge(@steps, overrides)}

  describe "a steps policy" do
    # Each row is a count of viewers with nobody having left, and the
    # interval of the step the count reaches.
    for {viewer_count, interval_ms} <- [{0, 60_000}, {1, 5_000}, {2, 5_000}, {10_000, 5_000}] do
      test "decides #{interval_ms} ms for #{viewer_count} viewers" do
        signals = %{viewer_count: unquote(viewer_count), viewer_absence_ms: nil}

        assert Cadence.interval_ms(steps(), signals) == unquote(interval_ms)
      end
    end

    # Each row is how long ago the last viewer left, around the hold of
    # 60,000 ms: just inside it, exactly at it, and just past it.
    for {label, viewer_absence_ms, interval_ms} <- [
          {"the moment the last viewer leaves", 0, 5_000},
          {"one millisecond inside the hold", 59_999, 5_000},
          {"exactly at the hold", 60_000, 60_000},
          {"one millisecond past the hold", 60_001, 60_000}
        ] do
      test "decides #{interval_ms} ms with no viewer #{label}" do
        signals = %{viewer_count: 0, viewer_absence_ms: unquote(viewer_absence_ms)}

        assert Cadence.interval_ms(steps(), signals) == unquote(interval_ms)
      end
    end

    test "decides the first step's interval at once under a hold of zero" do
      signals = %{viewer_count: 0, viewer_absence_ms: 0}

      assert Cadence.interval_ms(steps(%{hold_ms: 0}), signals) == 60_000
    end

    # Each row is a count of viewers and the step of a three-step table it
    # reaches: the last one whose least count is at most the count.
    for {viewer_count, interval_ms} <- [{0, 60_000}, {1, 15_000}, {9, 15_000}, {10, 5_000}] do
      test "decides #{interval_ms} ms for #{viewer_count} viewers under three steps" do
        policy =
          steps(%{
            steps: [
              %{viewer_count_min: 0, interval_ms: 60_000},
              %{viewer_count_min: 1, interval_ms: 15_000},
              %{viewer_count_min: 10, interval_ms: 5_000}
            ]
          })

        signals = %{viewer_count: unquote(viewer_count), viewer_absence_ms: nil}

        assert Cadence.interval_ms(policy, signals) == unquote(interval_ms)
      end
    end

    test "has its shortest interval as the shortest it can decide" do
      assert Cadence.interval_ms_min(steps()) == 5_000
    end

    for signals <- [
          %{},
          %{viewer_count: 1},
          %{viewer_absence_ms: nil},
          %{viewer_count: -1, viewer_absence_ms: nil},
          %{viewer_count: 1.0, viewer_absence_ms: nil},
          %{viewer_count: nil, viewer_absence_ms: nil},
          %{viewer_count: 0, viewer_absence_ms: -1},
          %{viewer_count: 0, viewer_absence_ms: 1.5}
        ] do
      test "refuses the signals #{inspect(signals)}" do
        assert_raise AssertionError, fn ->
          Cadence.interval_ms(steps(), unquote(Macro.escape(signals)))
        end
      end
    end

    test "is accepted by assert_policy/1" do
      assert Cadence.assert_policy(steps()) == :ok
    end

    test "is accepted with as many steps as the bound allows" do
      steps =
        for index <- 0..(Cadence.step_count_max() - 1) do
          %{viewer_count_min: index, interval_ms: 60_000 - index}
        end

      assert Cadence.assert_policy(steps(%{steps: steps})) == :ok
    end

    test "is refused with one step more than the bound allows" do
      steps =
        for index <- 0..Cadence.step_count_max() do
          %{viewer_count_min: index, interval_ms: 60_000 - index}
        end

      assert_raise AssertionError, ~r/steps/, fn ->
        Cadence.assert_policy(steps(%{steps: steps}))
      end
    end

    # Each row replaces one field of a policy that is otherwise accepted.
    for {label, overrides} <- [
          {"a shortest interval over the longest", %{interval_ms_min: 60_001}},
          {"a shortest interval of zero", %{interval_ms_min: 0}},
          {"a hold under zero", %{hold_ms: -1}},
          {"a hold that is not an integer", %{hold_ms: 60_000.0}},
          {"no step", %{steps: []}},
          {"steps that are not a list", %{steps: %{0 => 60_000}}},
          {"no step for a count of zero", %{steps: [%{viewer_count_min: 1, interval_ms: 5_000}]}},
          {"steps out of order",
           %{
             steps: [
               %{viewer_count_min: 0, interval_ms: 60_000},
               %{viewer_count_min: 2, interval_ms: 5_000},
               %{viewer_count_min: 1, interval_ms: 5_000}
             ]
           }},
          {"two steps for one count",
           %{
             steps: [
               %{viewer_count_min: 0, interval_ms: 60_000},
               %{viewer_count_min: 0, interval_ms: 5_000}
             ]
           }},
          {"a step interval under the shortest",
           %{
             steps: [
               %{viewer_count_min: 0, interval_ms: 60_000},
               %{viewer_count_min: 1, interval_ms: 4_999}
             ]
           }},
          {"a step interval over the longest",
           %{steps: [%{viewer_count_min: 0, interval_ms: 60_001}]}},
          {"a step count that is not an integer",
           %{steps: [%{viewer_count_min: 0.0, interval_ms: 60_000}]}},
          {"a step without an interval", %{steps: [%{viewer_count_min: 0}]}}
        ] do
      test "is refused with #{label}" do
        policy = steps(unquote(Macro.escape(overrides)))

        assert_raise AssertionError, fn -> Cadence.assert_policy(policy) end
      end
    end

    for field <- [:interval_ms_min, :interval_ms_max, :steps, :hold_ms] do
      test "is refused without #{field}" do
        policy = {:steps, Map.delete(@steps, unquote(field))}

        assert_raise AssertionError, fn -> Cadence.assert_policy(policy) end
      end
    end
  end
end
