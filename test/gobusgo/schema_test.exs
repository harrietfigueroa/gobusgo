defmodule Gobusgo.SchemaTest do
  # Verifies the schema check as a pure function that returns the first
  # mismatch as a value: each case names a value, a schema, and the path and
  # expectation the mismatch must carry.
  use ExUnit.Case, async: true

  alias Gobusgo.Schema

  @schema {:map,
           %{
             "name" => :string,
             "count" => :integer,
             "ratio" => :number,
             "open" => :boolean,
             "kind" => {:literal, "agency"},
             "tags" => {:list, :string}
           }}

  @valid %{
    "name" => "Metro",
    "count" => 2,
    "ratio" => 0.5,
    "open" => true,
    "kind" => "agency",
    "tags" => ["a", "b"]
  }

  describe "mismatch/2" do
    test "returns nil for a matching value, ignoring unknown map keys" do
      assert Schema.mismatch(Map.put(@valid, "extra", 1), @schema) == nil
    end

    for {description, key, value, path, expected} <- [
          {"a wrong string", "name", 1, ["name"], :string},
          {"a wrong integer", "count", 1.5, ["count"], :integer},
          {"a wrong number", "ratio", "x", ["ratio"], :number},
          {"a wrong boolean", "open", "yes", ["open"], :boolean},
          {"a wrong literal", "kind", "stop", ["kind"], {:literal, "agency"}},
          {"a wrong list element", "tags", ["a", 2], ["tags", 1], :string},
          {"a list that is not a list", "tags", "a", ["tags"], {:list, :string}}
        ] do
      test "returns the path and the expectation for #{description}" do
        value = Map.put(@valid, unquote(key), unquote(Macro.escape(value)))

        assert Schema.mismatch(value, @schema) ==
                 %{path: unquote(path), expected: unquote(Macro.escape(expected))}
      end
    end

    test "returns the missing key as required" do
      assert Schema.mismatch(Map.delete(@valid, "name"), @schema) ==
               %{path: ["name"], expected: :required}
    end

    test "returns the root path for a value that is not a map" do
      assert %{path: []} = Schema.mismatch("text", @schema)
    end
  end

  describe "mismatch/2 with a nullable schema" do
    @nullable_schema {:map, %{"position" => {:nullable, {:map, %{"lat" => :number}}}}}

    test "returns nil for a null value" do
      assert Schema.mismatch(%{"position" => nil}, @nullable_schema) == nil
    end

    test "returns nil for a value that matches the inner schema" do
      assert Schema.mismatch(%{"position" => %{"lat" => 47.5}}, @nullable_schema) == nil
    end

    test "returns the inner mismatch for a value that is neither" do
      assert Schema.mismatch(%{"position" => %{"lat" => "north"}}, @nullable_schema) ==
               %{path: ["position", "lat"], expected: :number}
    end

    test "returns a missing nullable key as required" do
      assert Schema.mismatch(%{}, @nullable_schema) == %{path: ["position"], expected: :required}
    end
  end

  describe "mismatch/2 with an optional schema" do
    @optional_schema {:map, %{"location" => {:optional, {:map, %{"lat" => :number}}}}}

    test "returns nil for an absent key" do
      assert Schema.mismatch(%{}, @optional_schema) == nil
    end

    test "returns nil for a present value that matches the inner schema" do
      assert Schema.mismatch(%{"location" => %{"lat" => 47.5}}, @optional_schema) == nil
    end

    test "returns the inner mismatch for a present value that does not match" do
      assert Schema.mismatch(%{"location" => %{"lat" => "north"}}, @optional_schema) ==
               %{path: ["location", "lat"], expected: :number}
    end

    test "returns the inner expectation for a present null" do
      assert Schema.mismatch(%{"location" => nil}, @optional_schema) ==
               %{path: ["location"], expected: {:map, %{"lat" => :number}}}
    end
  end

  describe "format_path/1" do
    test "names the root for an empty path" do
      assert Schema.format_path([]) == "root"
    end

    test "joins keys and indexes with dots" do
      assert Schema.format_path(["data", "list", 0, "lat"]) == "data.list.0.lat"
    end
  end
end
