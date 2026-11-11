defmodule Gobusgo.Intersections.StreetsTest do
  # Groups hand-written intersections under both of their streets.
  use ExUnit.Case, async: true

  alias Gobusgo.Intersections.Streets

  @intersections [
    %{
      first: "3RD AVE",
      second: "PINE ST",
      lat_microdegrees: 47_612_000,
      lon_microdegrees: -122_336_500
    },
    %{
      first: "3RD AVE",
      second: "PIKE ST",
      lat_microdegrees: 47_610_700,
      lon_microdegrees: -122_337_100
    }
  ]

  test "stores each crossing under both streets" do
    streets = Streets.group(@intersections)

    assert Enum.map(streets, & &1.key) == ["3RD AVE", "PIKE ST", "PINE ST"]
    assert [%{crossings: third}, %{crossings: [pike]}, %{crossings: [pine]}] = streets
    assert length(third) == 2
    assert pike.other == "3RD AVE"
    assert pine.other == "3RD AVE"
  end

  test "orders a street's crossings by position" do
    [third | _rest] = Streets.group(@intersections)
    assert Enum.map(third.crossings, & &1.other) == ["PIKE ST", "PINE ST"]
  end

  test "orders the streets by shard key and carries it" do
    streets = Streets.group(@intersections)
    assert Enum.map(streets, & &1.name_key) == ["3RD", "PIKE", "PINE"]
  end
end
