defmodule Gobusgo.FilterTest do
  # Verifies the filter contract as pure functions: each case hands
  # `normalize/1` a raw filter as a transport would decode it and names the
  # filter or the violations it must return, and hands `matches?/1` a filter
  # and one record's field values.
  use ExUnit.Case, async: true

  alias Gobusgo.Filter

  @spec_fields %{"agency" => :string, "route" => :string}

  defp normalize(raw), do: Filter.normalize(%{raw: raw, spec: @spec_fields})

  describe "normalize/1 with a valid raw filter" do
    for {description, raw, filter} <- [
          {"no field", %{}, %{}},
          {"one value as a string", %{"agency" => "1"}, %{"agency" => ["1"]}},
          {"one value as a list", %{"agency" => ["1"]}, %{"agency" => ["1"]}},
          {"several values, sorted", %{"agency" => ["40", "1"]}, %{"agency" => ["1", "40"]}},
          {"a repeated value, once", %{"agency" => ["1", "1"]}, %{"agency" => ["1"]}},
          {"several fields", %{"agency" => "1", "route" => ["1_100"]},
           %{"agency" => ["1"], "route" => ["1_100"]}},
          {"a blank string, as an absent field", %{"agency" => ""}, %{}},
          {"an empty list, as an absent field", %{"agency" => []}, %{}},
          {"a blank value among others, dropped", %{"agency" => ["", "1"]}, %{"agency" => ["1"]}}
        ] do
      test "returns the filter for #{description}" do
        assert normalize(unquote(Macro.escape(raw))) == {:ok, unquote(Macro.escape(filter))}
      end
    end

    test "accepts as many values as the limit allows" do
      values = for index <- 1..Filter.value_count_max(), do: Integer.to_string(index)

      assert {:ok, %{"agency" => accepted}} = normalize(%{"agency" => values})
      assert length(accepted) == Filter.value_count_max()
    end

    test "accepts a value as long as the limit allows" do
      value = String.duplicate("a", Filter.value_bytes_max())

      assert normalize(%{"agency" => value}) == {:ok, %{"agency" => [value]}}
    end
  end

  describe "normalize/1 with an invalid raw filter" do
    for {description, raw_value, reason} <- [
          {"a value that is not a string", 1, :invalid_value},
          {"a map of values", %{"0" => "1"}, :invalid_value},
          {"a list element that is not a string", ["1", 2], :invalid_value},
          {"a value that is not UTF-8", <<0xFF>>, :invalid_value}
        ] do
      test "returns #{reason} for #{description}" do
        assert normalize(%{"agency" => unquote(Macro.escape(raw_value))}) ==
                 {:error, [%{field: "agency", reason: unquote(reason)}]}
      end
    end

    test "returns unknown_field for a field the specification does not name" do
      assert normalize(%{"color" => "red"}) ==
               {:error, [%{field: "color", reason: :unknown_field}]}
    end

    test "returns too_many_values for one value past the limit" do
      values = for index <- 0..Filter.value_count_max(), do: Integer.to_string(index)

      assert normalize(%{"agency" => values}) ==
               {:error, [%{field: "agency", reason: :too_many_values}]}
    end

    test "returns value_too_long for a value one byte past the limit" do
      value = String.duplicate("a", Filter.value_bytes_max() + 1)

      assert normalize(%{"agency" => value}) ==
               {:error, [%{field: "agency", reason: :value_too_long}]}
    end

    test "returns every violation, in field order, and no part of the filter" do
      assert normalize(%{"route" => 1, "agency" => "1", "color" => "red"}) ==
               {:error,
                [
                  %{field: "color", reason: :unknown_field},
                  %{field: "route", reason: :invalid_value}
                ]}
    end

    test "returns one too_many_fields violation for a field past the limit" do
      raw = for index <- 0..Filter.field_count_max(), into: %{}, do: {"field#{index}", "1"}

      assert normalize(raw) == {:error, [%{field: nil, reason: :too_many_fields}]}
    end
  end

  describe "matches?/1" do
    @filter %{"agency" => ["1", "40"], "route" => ["1_100"]}

    for {description, values, matches} <- [
          {"every field holds an accepted value", %{"agency" => "40", "route" => "1_100"}, true},
          {"one field holds another value", %{"agency" => "40", "route" => "1_200"}, false},
          {"one field's value is nil", %{"agency" => "40", "route" => nil}, false},
          {"one field is absent", %{"agency" => "40"}, false}
        ] do
      test "is #{matches} when #{description}" do
        assert Filter.matches?(%{filter: @filter, values: unquote(Macro.escape(values))}) ==
                 unquote(matches)
      end
    end

    test "is true for the empty filter, whatever the values" do
      assert Filter.matches?(%{filter: %{}, values: %{"agency" => nil}})
    end

    test "ignores the values of fields the filter does not name" do
      assert Filter.matches?(%{
               filter: %{"agency" => ["1"]},
               values: %{"agency" => "1", "x" => "y"}
             })
    end
  end
end
