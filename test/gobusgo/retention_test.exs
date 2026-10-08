defmodule Gobusgo.RetentionTest do
  # Verifies the retention rules as pure functions of a rule, a destination,
  # and a date, around the day content expires, and over destinations that
  # name no day at all.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Retention

  @rule %{prefix: "raw/oba/vehicles-for-agency", day_count: 1}
  @destination "raw/oba/vehicles-for-agency/dt=2026-10-02/agency=1/a.json.gz"

  defp status(today, changes \\ %{}) do
    Retention.status(Map.merge(%{rule: @rule, destination: @destination, today: today}, changes))
  end

  describe "status/1" do
    for {today, status} <- [
          {~D[2026-10-01], :kept},
          {~D[2026-10-02], :kept},
          {~D[2026-10-03], :kept},
          {~D[2026-10-04], :expired},
          {~D[2026-11-02], :expired}
        ] do
      test "calls content of 2 October #{status} on #{today} under a rule of one day" do
        assert status(unquote(Macro.escape(today))) == unquote(status)
      end
    end

    for {day_count, today, status} <- [
          {3, ~D[2026-10-05], :kept},
          {3, ~D[2026-10-06], :expired},
          {30, ~D[2026-11-01], :kept},
          {30, ~D[2026-11-02], :expired}
        ] do
      test "calls content of 2 October #{status} on #{today} under a rule of #{day_count} days" do
        rule = %{@rule | day_count: unquote(day_count)}

        assert status(unquote(Macro.escape(today)), %{rule: rule}) == unquote(status)
      end
    end

    test "judges content directly below its day" do
      rule = %{prefix: "usage/page-connections", day_count: 1}
      destination = "usage/page-connections/dt=2026-10-02/a.json.gz"

      assert status(~D[2026-10-04], %{rule: rule, destination: destination}) == :expired
    end

    for {label, destination} <- [
          {"a segment that is no day", "raw/oba/vehicles-for-agency/agency=1/a.json.gz"},
          {"a day that is no date",
           "raw/oba/vehicles-for-agency/dt=2026-13-40/agency=1/a.json.gz"},
          {"a day with text after the date",
           "raw/oba/vehicles-for-agency/dt=2026-10-02x/agency=1/a.json.gz"},
          {"a day with nothing below it", "raw/oba/vehicles-for-agency/dt=2026-10-02"},
          {"another dataset", "raw/oba/routes-for-agency/dt=2026-10-02/agency=1/a.json.gz"},
          {"a dataset whose name starts with the prefix",
           "raw/oba/vehicles-for-agency-old/dt=2026-10-02/agency=1/a.json.gz"}
        ] do
      test "calls #{label} unrecognized, however old" do
        assert status(~D[2030-01-01], %{destination: unquote(destination)}) == :unrecognized
      end
    end
  end

  describe "within/1 and partitions_prefix/1" do
    test "name the dataset and its days" do
      assert Retention.within(@rule) == "raw/oba/vehicles-for-agency/"
      assert Retention.partitions_prefix(@rule) == "raw/oba/vehicles-for-agency/dt="
    end

    test "has every judged destination start with both" do
      assert String.starts_with?(@destination, Retention.within(@rule))
      assert String.starts_with?(@destination, Retention.partitions_prefix(@rule))
    end
  end

  describe "assert_rule/1" do
    test "accepts a rule" do
      assert Retention.assert_rule(@rule) == :ok
    end

    for {label, rule} <- [
          {"a prefix that ends in /", %{prefix: "raw/oba/", day_count: 1}},
          {"an empty prefix", %{prefix: "", day_count: 1}},
          {"a prefix that is no string", %{prefix: nil, day_count: 1}},
          {"no days", %{prefix: "raw", day_count: 0}},
          {"days that are no integer", %{prefix: "raw", day_count: 1.5}},
          {"more days than ten years", %{prefix: "raw", day_count: 3_651}},
          {"a rule that is no map", [prefix: "raw", day_count: 1]}
        ] do
      test "refuses #{label}" do
        assert_raise AssertionError, fn -> Retention.assert_rule(unquote(Macro.escape(rule))) end
      end
    end
  end
end
