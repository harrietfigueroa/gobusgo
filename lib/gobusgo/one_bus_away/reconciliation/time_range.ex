defmodule Gobusgo.OneBusAway.Reconciliation.TimeRange do
  @date_count_max 32

  @moduledoc """
  The half-open time range `[start_at, end_at)` that one reconciliation
  covers. Everything here is pure.

  Both bounds are UTC times at whole seconds, `start_at` is before `end_at`,
  and a range touches at most #{@date_count_max} UTC dates.
  """

  alias Gobusgo.Assert

  @type t :: %{start_at: DateTime.t(), end_at: DateTime.t()}

  @utc_time_zone "Etc/UTC"

  @doc "Raises `Gobusgo.Assert.AssertionError` unless `range` obeys the range rules."
  @spec assert_valid(t()) :: :ok
  def assert_valid(%{start_at: %DateTime{} = start_at, end_at: %DateTime{} = end_at} = range) do
    assert_bound(start_at, "start_at")
    assert_bound(end_at, "end_at")

    Assert.condition(
      DateTime.compare(start_at, end_at) == :lt,
      "start_at must be before end_at: #{start_at} and #{end_at}"
    )

    date_count = Date.diff(last_date(range), DateTime.to_date(start_at)) + 1

    Assert.condition(
      date_count <= @date_count_max,
      "range touches #{date_count} dates, at most #{@date_count_max} allowed"
    )
  end

  @doc "Returns every UTC date that holds an instant of the range, in order."
  @spec dates(t()) :: [Date.t(), ...]
  def dates(%{start_at: start_at} = range) do
    start_at |> DateTime.to_date() |> Date.range(last_date(range)) |> Enum.to_list()
  end

  @doc "Returns whether `time` falls in the range: at or after the start, before the end."
  @spec member?(t(), DateTime.t()) :: boolean()
  def member?(%{start_at: start_at, end_at: end_at}, %DateTime{} = time) do
    DateTime.compare(time, start_at) != :lt and DateTime.compare(time, end_at) == :lt
  end

  # The end is exclusive, so the last instant of the range is one second
  # before it: a range ending at midnight leaves that date out.
  defp last_date(%{end_at: end_at}) do
    end_at |> DateTime.add(-1, :second) |> DateTime.to_date()
  end

  defp assert_bound(%DateTime{time_zone: time_zone, microsecond: {microsecond, _precision}}, name) do
    Assert.condition(time_zone == @utc_time_zone, "#{name} must be in UTC, got: #{time_zone}")

    Assert.condition(
      microsecond == 0,
      "#{name} must be at a whole second, got #{microsecond} microseconds"
    )
  end
end
