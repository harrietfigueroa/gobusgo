defmodule Gobusgo.Intersections.OplTest do
  # Reads single lines of osmium's OPL format.
  use ExUnit.Case, async: true

  alias Gobusgo.Intersections.Opl

  test "reads a way's identifier, decoded tags, and node identifiers" do
    line = "w7 Thighway=residential,name=Pine%20%Street,note=a%2c%b Nn1,n2,n3"

    assert Opl.way(line) ==
             {:ok,
              %{
                id: 7,
                tags: %{"highway" => "residential", "name" => "Pine Street", "note" => "a,b"},
                node_ids: [1, 2, 3]
              }}
  end

  test "decodes a code point of more than one byte" do
    assert {:ok, %{tags: %{"name" => "Café"}}} = Opl.way("w7 Tname=Caf%e9% Nn1")
  end

  test "leaves a percent sequence that is not a code point as it is" do
    assert {:ok, %{tags: %{"name" => "a%110000%"}}} = Opl.way("w7 Tname=a%110000% Nn1")
  end

  test "reads a way with no tags and no nodes" do
    assert Opl.way("w7 T N") == {:ok, %{id: 7, tags: %{}, node_ids: []}}
  end

  test "skips the lines of other types" do
    assert Opl.way("n7 T x1 y2") == :skip
    assert Opl.node("w7 T N") == :skip
    assert Opl.node_id("r7 T M") == :skip
  end

  test "reports a malformed line as a value" do
    assert Opl.way("wx Tname=a Nn1") == :malformed
    assert Opl.way("w7 Tname=a Nn1,x2") == :malformed
    assert Opl.node("n7 T x1") == :malformed
    assert Opl.node("n7 T xa y2") == :malformed
    assert Opl.node_id("nx T x1 y2") == :malformed
  end

  test "reads a node's position" do
    assert Opl.node("n7 Thighway=traffic_signals x-122.3371 y47") ==
             {:ok, %{id: 7, lat: 47.0, lon: -122.3371}}
  end

  test "reads a node's identifier alone" do
    assert Opl.node_id("n7 T x-122.3 y47.6") == {:ok, 7}
  end
end
