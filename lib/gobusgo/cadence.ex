defmodule Gobusgo.Cadence do
  @step_count_max 8
  @hold_viewer_count 1

  @moduledoc """
  How often a poller polls: the interval a policy decides from the signals
  it is given. Everything here is pure: the caller reads the signals and
  passes them in, and nothing here reads a process or a clock, so a policy
  is tested with values alone.

  A policy is a tagged tuple, and each kind of policy is one clause of
  `interval_ms/2`, `interval_ms_min/1`, and `assert_policy/1`:

    * `{:fixed, interval_ms}`: always `interval_ms`, whatever the signals.
    * `{:steps, steps_policy}`: the interval of a step table from the count
      of viewers. `:steps` is the table, a list of at most
      #{@step_count_max} steps, each a map with `:viewer_count_min`, the
      least count the step applies to, and `:interval_ms`. The steps are in
      ascending order of `:viewer_count_min`, the first one's is zero, and
      the policy decides the interval of the last step whose
      `:viewer_count_min` is at most the count. `:hold_ms` is the hold: with
      no viewer, and the last one gone for under `:hold_ms`, the policy
      decides as for #{@hold_viewer_count} viewer. The map also holds the
      policy's bounds, which every step's interval is inside. Its signals
      are `:viewer_count`, a non-negative integer, and `:viewer_absence_ms`,
      how long ago the count was last above zero: a non-negative integer of
      milliseconds, zero while the count is above zero, and `nil` when the
      count has not been above zero for as long as the signals' source
      remembers.
    * `{:proportional, parameters}`: the count of items times
      `parameters.item_spacing_ms`, the milliseconds each item adds, brought
      inside the bounds `parameters` holds. No item decides the shortest
      interval. Its signal is `:item_count`, how many items share the
      interval, a non-negative integer.

  The signals are a map of what a policy decides from, and a policy reads
  the keys it knows. Signals without a key a policy reads, or with a value
  outside what the policy states for it, raise an assertion error.

  A policy whose decision varies carries bounds, a map with
  `:interval_ms_min`, the shortest interval it may decide, and
  `:interval_ms_max`, the longest. `assert_bounds/1` checks them and
  `clamp/2` brings a computed interval inside them.
  """

  alias Gobusgo.Assert

  @type step :: %{viewer_count_min: non_neg_integer(), interval_ms: pos_integer()}
  @type steps_policy :: %{
          interval_ms_min: pos_integer(),
          interval_ms_max: pos_integer(),
          steps: [step(), ...],
          hold_ms: non_neg_integer()
        }
  @type proportional_policy :: %{
          interval_ms_min: pos_integer(),
          interval_ms_max: pos_integer(),
          item_spacing_ms: pos_integer()
        }
  @type policy ::
          {:fixed, pos_integer()}
          | {:steps, steps_policy()}
          | {:proportional, proportional_policy()}
  @type signals :: map()
  @type bounds :: %{
          required(:interval_ms_min) => pos_integer(),
          required(:interval_ms_max) => pos_integer(),
          optional(atom()) => term()
        }

  @doc "The most steps the table of a steps policy has."
  @spec step_count_max() :: pos_integer()
  def step_count_max, do: @step_count_max

  @doc """
  Returns the interval `policy` decides from `signals`, in milliseconds: a
  positive integer, never under `interval_ms_min(policy)`. `signals` must be
  a map. Raises an assertion error for a policy of an unknown shape.
  """
  @spec interval_ms(policy(), signals()) :: pos_integer()
  def interval_ms(policy, signals) do
    assert_policy(policy)
    Assert.condition(is_map(signals), "signals must be a map, got: #{inspect(signals)}")
    interval_ms = decide(policy, signals)
    assert_interval(interval_ms, "the decided interval")
    interval_ms_min = interval_ms_min(policy)

    Assert.condition(
      interval_ms >= interval_ms_min,
      "the decided interval must be at least #{interval_ms_min}, got: #{interval_ms}"
    )

    interval_ms
  end

  @doc """
  Returns the shortest interval `policy` can decide, in milliseconds. Raises
  an assertion error for a policy of an unknown shape.
  """
  @spec interval_ms_min(policy()) :: pos_integer()
  def interval_ms_min({:fixed, interval_ms}), do: interval_ms
  def interval_ms_min({:steps, %{interval_ms_min: interval_ms_min}}), do: interval_ms_min
  def interval_ms_min({:proportional, %{interval_ms_min: interval_ms_min}}), do: interval_ms_min
  def interval_ms_min(policy), do: Assert.unreachable(policy)

  @doc """
  Returns `:ok` for a policy of a known shape whose values are valid, and
  raises an assertion error for any other.
  """
  @spec assert_policy(policy()) :: :ok
  def assert_policy({:fixed, interval_ms}), do: assert_interval(interval_ms, "interval_ms")

  def assert_policy({:steps, %{steps: steps, hold_ms: hold_ms} = bounds}) when is_list(steps) do
    assert_bounds(bounds)
    Assert.condition(is_integer(hold_ms), "hold_ms must be an integer, got: #{inspect(hold_ms)}")
    Assert.condition(hold_ms >= 0, "hold_ms must not be negative, got: #{hold_ms}")
    step_count = length(steps)
    Assert.condition(step_count >= 1, "steps must hold at least one step")

    Assert.condition(
      step_count <= @step_count_max,
      "steps must hold at most #{@step_count_max} steps, got: #{step_count}"
    )

    Enum.each(steps, &assert_step(&1, bounds))
    assert_step_order(Enum.map(steps, & &1.viewer_count_min))
  end

  def assert_policy({:proportional, %{item_spacing_ms: item_spacing_ms} = parameters}) do
    assert_bounds(parameters)
    assert_interval(item_spacing_ms, "item_spacing_ms")
  end

  def assert_policy(policy), do: Assert.unreachable(policy)

  @doc """
  Returns `:ok` when `bounds` holds two positive integers with
  `:interval_ms_min` at most `:interval_ms_max`, and raises an assertion
  error otherwise. The map may hold other keys.
  """
  @spec assert_bounds(bounds()) :: :ok
  def assert_bounds(%{interval_ms_min: interval_ms_min, interval_ms_max: interval_ms_max}) do
    assert_interval(interval_ms_min, "interval_ms_min")
    assert_interval(interval_ms_max, "interval_ms_max")

    Assert.condition(
      interval_ms_min <= interval_ms_max,
      "interval_ms_min must be at most interval_ms_max, got: #{interval_ms_min} over #{interval_ms_max}"
    )
  end

  def assert_bounds(bounds), do: Assert.unreachable(bounds)

  @doc """
  Returns `interval_ms` when it is inside `bounds`, and otherwise the bound
  it is past. `interval_ms` is any integer, zero and negative ones among
  them; `bounds` must pass `assert_bounds/1`.
  """
  @spec clamp(integer(), bounds()) :: pos_integer()
  def clamp(interval_ms, bounds) do
    assert_bounds(bounds)

    Assert.condition(
      is_integer(interval_ms),
      "a computed interval must be an integer, got: #{inspect(interval_ms)}"
    )

    clamped_ms = interval_ms |> max(bounds.interval_ms_min) |> min(bounds.interval_ms_max)
    Assert.condition(clamped_ms >= bounds.interval_ms_min, "a clamped interval is too short")
    Assert.condition(clamped_ms <= bounds.interval_ms_max, "a clamped interval is too long")
    clamped_ms
  end

  defp decide({:fixed, interval_ms}, _signals), do: interval_ms

  defp decide({:steps, %{steps: steps} = bounds}, signals) do
    viewer_count = steps_viewer_count(bounds, signals)
    step = steps |> Enum.filter(&(&1.viewer_count_min <= viewer_count)) |> List.last()
    Assert.condition(step != nil, "a step must apply to the count #{viewer_count}")
    clamp(step.interval_ms, bounds)
  end

  defp decide({:proportional, parameters}, signals) do
    Assert.condition(
      is_map_key(signals, :item_count),
      "a proportional policy needs the signal item_count, got: #{inspect(Map.keys(signals))}"
    )

    item_count = signals.item_count

    Assert.condition(
      is_integer(item_count),
      "item_count must be an integer, got: #{inspect(item_count)}"
    )

    Assert.condition(item_count >= 0, "item_count must be zero or more, got: #{item_count}")

    # The count is capped at the first one whose product passes the longest
    # interval, which bounds the product whatever the count.
    item_count_saturated =
      Integer.floor_div(parameters.interval_ms_max, parameters.item_spacing_ms) + 1

    clamp(min(item_count, item_count_saturated) * parameters.item_spacing_ms, parameters)
  end

  defp decide(policy, _signals), do: Assert.unreachable(policy)

  # The count a steps policy looks up in its table: the count of the
  # signals, or the count the hold stands in for it.
  defp steps_viewer_count(%{hold_ms: hold_ms}, signals) do
    Assert.condition(is_map_key(signals, :viewer_count), "signals must hold viewer_count")

    Assert.condition(
      is_map_key(signals, :viewer_absence_ms),
      "signals must hold viewer_absence_ms"
    )

    %{viewer_count: viewer_count, viewer_absence_ms: viewer_absence_ms} = signals
    assert_count(viewer_count, "viewer_count")

    case {viewer_count, viewer_absence_ms} do
      {0, nil} ->
        0

      {0, viewer_absence_ms} ->
        assert_count(viewer_absence_ms, "viewer_absence_ms")

        if viewer_absence_ms < hold_ms do
          @hold_viewer_count
        else
          0
        end

      {viewer_count, _viewer_absence_ms} ->
        viewer_count
    end
  end

  defp assert_step(step, bounds) do
    Assert.condition(is_map(step), "a step must be a map, got: #{inspect(step)}")
    assert_count(step[:viewer_count_min], "a step's viewer_count_min")
    interval_ms = step[:interval_ms]
    assert_interval(interval_ms, "a step's interval_ms")

    Assert.condition(
      interval_ms >= bounds.interval_ms_min,
      "a step's interval_ms must be at least #{bounds.interval_ms_min}, got: #{interval_ms}"
    )

    Assert.condition(
      interval_ms <= bounds.interval_ms_max,
      "a step's interval_ms must be at most #{bounds.interval_ms_max}, got: #{interval_ms}"
    )
  end

  defp assert_step_order([first | _rest] = viewer_count_mins) do
    Assert.condition(first == 0, "the first step must apply to a count of zero, got: #{first}")

    Assert.condition(
      viewer_count_mins == Enum.sort(viewer_count_mins),
      "steps must be in ascending order of viewer_count_min"
    )

    Assert.condition(
      viewer_count_mins == Enum.uniq(viewer_count_mins),
      "steps must each have a viewer_count_min of their own"
    )
  end

  defp assert_count(count, label) do
    Assert.condition(is_integer(count), "#{label} must be an integer, got: #{inspect(count)}")
    Assert.condition(count >= 0, "#{label} must not be negative, got: #{count}")
  end

  defp assert_interval(interval_ms, label) do
    Assert.condition(
      is_integer(interval_ms),
      "#{label} must be an integer, got: #{inspect(interval_ms)}"
    )

    Assert.condition(interval_ms >= 1, "#{label} must be positive, got: #{interval_ms}")
  end
end
