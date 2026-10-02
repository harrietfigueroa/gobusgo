defmodule Gobusgo.OneBusAway.AgencyBatch.Window do
  @date_count_max 32

  @moduledoc """
  The half-open time window `[start_at, end_at)` that defines one agency
  batch. Everything here is pure.

  Both bounds are UTC times at whole seconds, `start_at` is before `end_at`,
  and a window touches at most #{@date_count_max} UTC dates.
  """

  alias Gobusgo.Assert

  @type t :: %{start_at: DateTime.t(), end_at: DateTime.t()}

  @utc_time_zone "Etc/UTC"

  @doc "Raises `Gobusgo.Assert.AssertionError` unless `window` obeys the window rules."
  @spec assert_valid(t()) :: :ok
  def assert_valid(%{start_at: %DateTime{} = start_at, end_at: %DateTime{} = end_at} = window) do
    assert_bound(start_at, "start_at")
    assert_bound(end_at, "end_at")

    Assert.condition(
      DateTime.compare(start_at, end_at) == :lt,
      "start_at must be before end_at: #{id(window)}"
    )

    date_count = Date.diff(last_date(window), DateTime.to_date(start_at)) + 1

    Assert.condition(
      date_count <= @date_count_max,
      "window touches #{date_count} dates, at most #{@date_count_max} allowed"
    )
  end

  @doc "Returns the batch identifier: both bounds in basic ISO 8601, joined by `-`."
  @spec id(t()) :: String.t()
  def id(%{start_at: start_at, end_at: end_at}) do
    DateTime.to_iso8601(start_at, :basic) <> "-" <> DateTime.to_iso8601(end_at, :basic)
  end

  @doc "Returns every UTC date that holds an instant of the window, in order."
  @spec dates(t()) :: [Date.t(), ...]
  def dates(%{start_at: start_at} = window) do
    start_at |> DateTime.to_date() |> Date.range(last_date(window)) |> Enum.to_list()
  end

  @doc "Returns whether `time` falls in the window: at or after the start, before the end."
  @spec member?(t(), DateTime.t()) :: boolean()
  def member?(%{start_at: start_at, end_at: end_at}, %DateTime{} = time) do
    DateTime.compare(time, start_at) != :lt and DateTime.compare(time, end_at) == :lt
  end

  @doc "Returns whether the window has ended at `now`, so no later fetch can fall in it."
  @spec closed?(t(), DateTime.t()) :: boolean()
  def closed?(%{end_at: end_at}, %DateTime{} = now) do
    DateTime.compare(end_at, now) != :gt
  end

  # The end is exclusive, so the last instant of the window is one second
  # before it: a window ending at midnight leaves that date out.
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
