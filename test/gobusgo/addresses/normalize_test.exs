defmodule Gobusgo.Addresses.NormalizeTest do
  # Drives the normalizer over the cases of the shared fixture that
  # `test/scripts/address_normalize_check.mjs` reads too, so the server's
  # index build and the browser's search reach one key for one street. Each
  # case of the fixture is a test of its own, so a failure names its input.
  use ExUnit.Case, async: true

  alias Gobusgo.Addresses.Normalize

  @fixture "../../fixtures/addresses/normalize.json"
           |> Path.expand(__DIR__)
           |> File.read!()
           |> JSON.decode!()

  defp street_json(street) do
    %{
      "preDirection" => street.pre_direction,
      "name" => street.name,
      "type" => street.type,
      "sufDirection" => street.suf_direction
    }
  end

  defp query_json(%{kind: :address} = query) do
    %{
      "kind" => "address",
      "number" => query.number,
      "numberSuffix" => query.number_suffix,
      "street" => street_json(query.street),
      "locality" => query.locality,
      "zip" => query.zip
    }
  end

  defp query_json(%{kind: :intersection} = query) do
    %{
      "kind" => "intersection",
      "first" => street_json(query.first),
      "second" => street_json(query.second),
      "locality" => query.locality,
      "zip" => query.zip
    }
  end

  defp query_json(%{kind: :street} = query) do
    %{
      "kind" => "street",
      "street" => street_json(query.street),
      "locality" => query.locality,
      "zip" => query.zip
    }
  end

  for {%{"input" => input, "street" => street, "key" => key}, index} <-
        Enum.with_index(@fixture["fields"]) do
    @case_input input
    @case_street street
    @case_key key

    test "street of the county fields #{inspect(input)} (#{index})" do
      input = %{
        pre_direction: @case_input["preDirection"],
        name: @case_input["name"],
        type: @case_input["type"],
        suf_direction: @case_input["sufDirection"]
      }

      actual = Normalize.street_from_fields(input)
      assert street_json(actual) == @case_street
      assert Normalize.street_key(actual) == @case_key
    end
  end

  for {%{"text" => text, "parsed" => parsed}, index} <- Enum.with_index(@fixture["queries"]) do
    @query_text text
    @query_parsed parsed

    test "query #{inspect(text)} (#{index})" do
      assert @query_text |> Normalize.parse_query() |> query_json() == @query_parsed
    end
  end

  test "a token past the token bound is left out" do
    text = Enum.map_join(1..40, " ", &"W#{&1}")
    assert length(Normalize.tokenize(text)) == Normalize.token_count_max()
  end

  test "a name of ten digits is not an ordinal" do
    assert Normalize.ordinal_token("1234567890") == "1234567890"
    assert Normalize.ordinal_token("123456789") == "123456789TH"
  end

  test "the name key of a street has no spaces" do
    street =
      Normalize.street_from_fields(%{
        pre_direction: "",
        name: "MARTIN LUTHER KING JR",
        type: "WAY",
        suf_direction: "S"
      })

    assert Normalize.name_key(street) == "MARTINLUTHERKINGJR"
  end
end
