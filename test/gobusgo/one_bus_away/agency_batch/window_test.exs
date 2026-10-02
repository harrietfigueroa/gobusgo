defmodule Gobusgo.OneBusAway.AgencyBatch.WindowTest do
  # Verifies the half-open batch window as pure functions over literal times:
  # its identifier, the UTC dates it touches, membership at both bounds, and
  # the rules a window must obey.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.AgencyBatch.Window

  @window %{start_at: ~U[2026-10-02 00:00:00Z], end_at: ~U[2026-10-03 00:00:00Z]}

  describe "id/1" do
    test "joins the bounds in basic ISO 8601" do
      assert Window.id(@window) == "20261002T000000Z-20261003T000000Z"
    end
  end

  describe "dates/1" do
    test "leaves out the date an end at midnight opens" do
      assert Window.dates(@window) == [~D[2026-10-02]]
    end

    test "lists every date a window across midnight touches" do
      window = %{start_at: ~U[2026-10-02 23:00:00Z], end_at: ~U[2026-10-04 00:00:01Z]}

      assert Window.dates(window) == [~D[2026-10-02], ~D[2026-10-03], ~D[2026-10-04]]
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
        assert Window.member?(@window, unquote(Macro.escape(time))) == unquote(expected)
      end
    end
  end

  describe "closed?/2" do
    test "is true once the end is reached" do
      assert Window.closed?(@window, ~U[2026-10-03 00:00:00Z])
    end

    test "is false before the end" do
      refute Window.closed?(@window, ~U[2026-10-02 23:59:59Z])
    end
  end

  describe "assert_valid/1" do
    test "returns :ok for a window in UTC at whole seconds" do
      assert Window.assert_valid(@window) == :ok
    end

    for {description, window, pattern} <- [
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
          Window.assert_valid(unquote(Macro.escape(window)))
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
        Window.assert_valid(%{@window | start_at: paris})
      end
    end
  end
end
