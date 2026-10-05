defmodule GobusgoWeb.FilterParamsTest do
  # Verifies the reading of a raw filter out of decoded query parameters as
  # a pure function: each case names the parameters and the raw filter the
  # filter contract is then handed.
  use ExUnit.Case, async: true

  alias GobusgoWeb.FilterParams

  @spec_fields %{"agency" => :string, "route" => :string}

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
