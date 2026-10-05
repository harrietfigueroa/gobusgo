defmodule GobusgoWeb.FilterParamsTest do
  # Verifies the reading of a raw filter out of decoded query parameters as
  # a pure function: each case names the parameters and the raw filter the
  # filter contract is then handed.
  use ExUnit.Case, async: true

  alias GobusgoWeb.FilterParams

  @spec_fields %{"agency" => :string, "route" => :string}

  alias Gobusgo.Filter

  describe "param/1" do
    test "joins a field's values into one parameter value" do
      assert FilterParams.param(["1_100", "40_500"]) == "1_100,40_500"
    end

    test "writes a value that reads back as the field's values" do
      params = %{"route" => FilterParams.param(["1_100", "40_500"])}

      assert FilterParams.raw(%{params: params, spec: @spec_fields}) ==
               %{"route" => ["1_100", "40_500"]}
    end
  end

  describe "query/1" do
    for {description, filter, query} <- [
          {"the empty filter", %{}, ""},
          {"one value", %{"agency" => ["40"]}, "agency=40"},
          {"several values", %{"agency" => ["1", "40"]}, "agency=1,40"},
          {"several fields, in field order", %{"route" => ["1_100"], "agency" => ["1"]},
           "agency=1&route=1_100"},
          {"a value with reserved characters", %{"agency" => ["a b&c"]}, "agency=a+b%26c"}
        ] do
      test "writes #{description}" do
        assert FilterParams.query(unquote(Macro.escape(filter))) == unquote(query)
      end
    end

    test "writes a filter that reads back as itself" do
      filter = %{"agency" => ["1", "a b&c"], "route" => ["1_100"]}
      params = filter |> FilterParams.query() |> URI.decode_query()

      assert Filter.normalize(%{
               raw: FilterParams.raw(%{params: params, spec: @spec_fields}),
               spec: @spec_fields
             }) == {:ok, filter}
    end
  end

  for {description, params, raw} <- [
        {"no parameter", %{}, %{}},
        {"one value", %{"agency" => "40"}, %{"agency" => ["40"]}},
        {"values separated by commas", %{"agency" => "1,40"}, %{"agency" => ["1", "40"]}},
        {"a blank parameter", %{"agency" => ""}, %{"agency" => [""]}},
        {"a blank between commas", %{"agency" => "1,,40"}, %{"agency" => ["1", "", "40"]}},
        {"several fields", %{"agency" => "1", "route" => "1_100,1_200"},
         %{"agency" => ["1"], "route" => ["1_100", "1_200"]}},
        {"a parameter that is no field", %{"agency" => "1", "page" => "2"}, %{"agency" => ["1"]}},
        {"a parameter that is not a string", %{"agency" => %{"x" => "1"}},
         %{"agency" => %{"x" => "1"}}}
      ] do
    test "reads #{description}" do
      assert FilterParams.raw(%{params: unquote(Macro.escape(params)), spec: @spec_fields}) ==
               unquote(Macro.escape(raw))
    end
  end
end
