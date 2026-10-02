defmodule Gobusgo.AssertTest do
  # Exercises the assertion helpers directly: passing values come back
  # unchanged, and every violation raises the shared assertion error.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert
  alias Gobusgo.Assert.AssertionError

  describe "condition/2" do
    test "returns :ok for a truthy condition" do
      assert Assert.condition(1 < 2, "one is less than two") == :ok
    end

    test "raises with the message for a falsy condition" do
      assert_raise AssertionError, "index 3 outside count 3", fn ->
        Assert.condition(3 < 3, "index 3 outside count 3")
      end
    end
  end

  describe "schema/2" do
    @schema {:map,
             %{
               "name" => :string,
               "tags" => {:list, :string},
               "span" => :number,
               "count" => :integer,
               "flag" => :boolean,
               "version" => {:literal, 2}
             }}

    @valid %{
      "name" => "a",
      "tags" => ["x"],
      "span" => 0.5,
      "count" => 1,
      "flag" => false,
      "version" => 2,
      "extra" => "ignored"
    }

    test "returns the value when it matches, ignoring unknown map keys" do
      assert Assert.schema(@valid, @schema) == @valid
    end

    test "accepts an integer where a number is expected" do
      assert Assert.schema(%{"span" => 1}, {:map, %{"span" => :number}}) == %{"span" => 1}
    end

    for {description, mutation} <- [
          {"a missing key", {:delete, "name"}},
          {"a wrong scalar type", {:put, "name", 5}},
          {"a wrong list element type", {:put, "tags", [1]}},
          {"a float where an integer is expected", {:put, "count", 1.5}},
          {"a different literal", {:put, "version", 3}}
        ] do
      test "raises with the mismatch path as the cause for #{description}" do
        value =
          case unquote(Macro.escape(mutation)) do
            {:delete, key} -> Map.delete(@valid, key)
            {:put, key, replacement} -> Map.put(@valid, key, replacement)
          end

        error = assert_raise AssertionError, fn -> Assert.schema(value, @schema) end
        assert error.cause.path != nil
      end
    end
  end
end
