defmodule Gobusgo.Cadence do
  @moduledoc """
  How often a poller polls: the interval a policy decides from the signals
  it is given. Everything here is pure: the caller reads the signals and
  passes them in, and nothing here reads a process or a clock, so a policy
  is tested with values alone.

  A policy is a tagged tuple, and each kind of policy is one clause of
  `interval_ms/2`, `interval_ms_min/1`, and `assert_policy/1`:

    * `{:fixed, interval_ms}`: always `interval_ms`, whatever the signals.

  The signals are a map of what a policy decides from, and a policy reads
  the keys it knows.

  A policy whose decision varies carries bounds, a map with
  `:interval_ms_min`, the shortest interval it may decide, and
  `:interval_ms_max`, the longest. `assert_bounds/1` checks them and
  `clamp/2` brings a computed interval inside them.
  """

  alias Gobusgo.Assert

  @type policy :: {:fixed, pos_integer()}
  @type signals :: map()
  @type bounds :: %{
          required(:interval_ms_min) => pos_integer(),
          required(:interval_ms_max) => pos_integer(),
          optional(atom()) => term()
        }

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
  def interval_ms_min(policy), do: Assert.unreachable(policy)

  @doc """
  Returns `:ok` for a policy of a known shape whose values are valid, and
  raises an assertion error for any other.
  """
  @spec assert_policy(policy()) :: :ok
  def assert_policy({:fixed, interval_ms}), do: assert_interval(interval_ms, "interval_ms")
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
  defp decide(policy, _signals), do: Assert.unreachable(policy)

  defp assert_interval(interval_ms, label) do
    Assert.condition(
      is_integer(interval_ms),
      "#{label} must be an integer, got: #{inspect(interval_ms)}"
    )

    Assert.condition(interval_ms >= 1, "#{label} must be positive, got: #{interval_ms}")
  end
end
