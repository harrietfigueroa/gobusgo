defmodule Gobusgo.CanonicalJsonTest do
  # Verifies the canonical encoding against hand-written literals, so the
  # encoder is never checked against itself.
  use ExUnit.Case, async: true

  alias Gobusgo.CanonicalJson

  describe "encode/1" do
    test "writes object keys in sorted order, compactly" do
      assert CanonicalJson.encode(%{
               "b" => 1,
               "a" => [1.5, "x"],
               "c" => %{"z" => nil, "y" => true}
             }) ==
               ~s({"a":[1.5,"x"],"b":1,"c":{"y":true,"z":null}})
    end

    test "sorts the keys of a map of any size" do
      value = Map.new(1..40, fn index -> {"k#{index}", index} end)

      expected =
        value
        |> Enum.sort()
        |> Enum.map_join(",", fn {key, number} -> ~s("#{key}":#{number}) end)

      assert CanonicalJson.encode(value) == "{" <> expected <> "}"
    end

    test "gives equal bytes for equal values built in a different order" do
      first = Map.new([{"a", 1}, {"b", 2}])
      second = Map.new([{"b", 2}, {"a", 1}])

      assert CanonicalJson.encode(first) == CanonicalJson.encode(second)
    end
  end
end
