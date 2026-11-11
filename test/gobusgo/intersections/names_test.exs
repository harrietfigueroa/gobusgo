defmodule Gobusgo.Intersections.NamesTest do
  # Checks the key a road is stored under against the normalizer's own rules.
  use ExUnit.Case, async: true

  alias Gobusgo.Addresses.Normalize
  alias Gobusgo.Intersections.Names

  for {name, key, name_key} <- [
        {"Pine Street", "PINE ST", "PINE"},
        {"3rd Avenue", "3RD AVE", "3RD"},
        {"Third Avenue", "3RD AVE", "3RD"},
        {"Northeast 45th Street", "NE 45TH ST", "45TH"},
        {"Martin Luther King Jr. Way South", "MARTIN LUTHER KING JR WAY S", "MARTINLUTHERKINGJR"}
      ] do
    test "keys #{name} as #{key}" do
      assert {:ok, %{key: unquote(key), name_key: unquote(name_key)}} = Names.key(unquote(name))
    end
  end

  test "reaches the key the normalizer gives a typed street" do
    typed =
      "Pine St" |> Normalize.tokenize() |> Normalize.parse_street() |> Normalize.street_key()

    assert {:ok, %{key: ^typed}} = Names.key("Pine Street")
  end

  test "refuses a name outside the alphabet" do
    assert Names.key("Café Row") == :unsupported
    assert Names.key("Pike/Pine Connector") == :unsupported
  end

  test "refuses a name with no name part" do
    assert Names.key("") == :unsupported
  end

  test "refuses a name of 200 characters" do
    assert Names.key(String.duplicate("A", 200)) == :unsupported
  end

  test "gives the shard key of a stored street key" do
    assert Names.name_key("N WEST AVE") == "WEST"
  end
end
