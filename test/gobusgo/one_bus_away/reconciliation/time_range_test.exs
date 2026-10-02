defmodule Gobusgo.OneBusAway.Reconciliation.TimeRangeTest do
  # Verifies the half-open time range as pure functions over literal times:
  # the UTC dates it touches, membership at both bounds, and the rules a
  # range must obey.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.Reconciliation.TimeRange

  @range %{start_at: ~U[2026-10-02 00:00:00Z], end_at: ~U[2026-10-03 00:00:00Z]}

  describe "dates/1" do
    test "leaves out the date an end at midnight opens" do
      assert TimeRange.dates(@range) == [~D[2026-10-02]]
    end

    test "lists every date a range across midnight touches" do
      range = %{start_at: ~U[2026-10-02 23:00:00Z], end_at: ~U[2026-10-04 00:00:01Z]}

      assert TimeRange.dates(range) == [~D[2026-10-02], ~D[2026-10-03], ~D[2026-10-04]]
    end
  end

  describe "member?/2" do
    for {description, time, expected} <- [
          {"the start", ~U[2026-10-02 00:00:00Z], true},
          {"a time inside", ~U[2026-10-02 12:00:00Z], true},
          {"the second before the end", ~U[2026-10-02 23:59:59Z], true},
          {"the end", ~U[2026-10-03 00:00:00Z], false},
          {"the second before the start", ~U[2026-10-01 23:59:59Z], false}
        ] do
      test "is #{expected} for #{description}" do
        assert TimeRange.member?(@range, unquote(Macro.escape(time))) == unquote(expected)
      end
    end
  end

  describe "assert_valid/1" do
    test "returns :ok for a range in UTC at whole seconds" do
      assert TimeRange.assert_valid(@range) == :ok
    end

    for {description, range, pattern} <- [
          {"an end equal to the start",
           %{start_at: ~U[2026-10-02 00:00:00Z], end_at: ~U[2026-10-02 00:00:00Z]}, ~r/before/},
          {"an end before the start",
           %{start_at: ~U[2026-10-03 00:00:00Z], end_at: ~U[2026-10-02 00:00:00Z]}, ~r/before/},
          {"a bound with a fraction of a second",
           %{start_at: ~U[2026-10-02 00:00:00.500Z], end_at: ~U[2026-10-03 00:00:00Z]},
           ~r/whole second/},
          {"more dates than the bound",
           %{start_at: ~U[2026-10-02 00:00:00Z], end_at: ~U[2026-11-04 00:00:00Z]}, ~r/dates/}
        ] do
      test "raises for #{description}" do
        assert_raise AssertionError, unquote(Macro.escape(pattern)), fn ->
          TimeRange.assert_valid(unquote(Macro.escape(range)))
        end
      end
    end

    test "raises for a bound outside UTC" do
      paris = %{
        ~U[2026-10-02 00:00:00Z]
        | utc_offset: 3600,
          time_zone: "Europe/Paris",
          zone_abbr: "CET"
      }

      assert_raise AssertionError, ~r/UTC/, fn ->
        TimeRange.assert_valid(%{@range | start_at: paris})
      end
    end
  end
end
