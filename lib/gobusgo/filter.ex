defmodule Gobusgo.Filter do
  @field_count_max 16
  @value_count_max 50
  @value_bytes_max 128

  @moduledoc """
  The filter contract every kind of record shares: which records a filter
  selects, and how a filter that arrives from outside becomes one the
  application acts on. Everything here is pure and nothing here reads a
  request, so every transport decodes its own input and validates it here.

  A kind of record names the fields it can be filtered by in a
  specification, and each field has a type. The one type is `:string`, whose
  values match by equality. The module that does so is an adapter of this
  contract: it implements `spec/0` and `values/1`, which reads the value of
  each field out of one record.

  A filter names some of those fields, each with the values it accepts. A
  record matches when every field the filter names holds one of that field's
  accepted values: the values of one field are alternatives, and the fields
  apply together. A record with no value for a named field does not match.
  The empty filter names no field and matches every record.

  A raw filter is a filter as a transport decodes it: each field holds a
  string or a list of strings. A blank value is dropped, and a field left
  with no value is absent. A normalized filter holds each field's values
  once and sorted, so equal filters are equal terms.

  A raw filter is accepted whole or not at all. It holds at most
  #{@field_count_max} fields, a field at most #{@value_count_max} values as
  sent, and a value at most #{@value_bytes_max} bytes.
  """

  alias Gobusgo.Assert

  @type field_type :: :string

  @typedoc "The fields a kind of record can be filtered by, and the type of each."
  @type spec :: %{String.t() => field_type()}

  @type raw :: %{String.t() => term()}

  @typedoc "Each named field's accepted values: at least one, unique, sorted."
  @type t :: %{String.t() => [String.t(), ...]}

  @typedoc """
    * `:unknown_field` — the specification does not name the field.
    * `:invalid_value` — the field holds something other than a string or a
      list of strings, or a string that is not UTF-8.
    * `:too_many_values` — the field holds more values than the limit.
    * `:value_too_long` — a value of the field is longer than the limit.
    * `:too_many_fields` — the raw filter holds more fields than the limit.
  """
  @type reason ::
          :unknown_field | :invalid_value | :too_many_values | :value_too_long | :too_many_fields

  @typedoc """
  One reason a raw filter is refused. `field` is the name the raw filter
  gave, or `nil` for a violation of the raw filter as a whole. A violation
  never holds a value.
  """
  @type violation :: %{field: String.t() | nil, reason: reason()}

  @typedoc "One record's value for each field, `nil` or absent where it has none."
  @type values :: %{String.t() => String.t() | nil}

  @doc "Returns the fields this kind of record can be filtered by."
  @callback spec() :: spec()

  @doc "Returns the value `record` holds for each field of `spec/0`."
  @callback values(record :: term()) :: values()

  @doc "Fields allowed in a specification and in a raw filter."
  @spec field_count_max() :: pos_integer()
  def field_count_max, do: @field_count_max

  @doc "Values allowed in one field of a raw filter."
  @spec value_count_max() :: pos_integer()
  def value_count_max, do: @value_count_max

  @doc "Bytes allowed in one value."
  @spec value_bytes_max() :: pos_integer()
  def value_bytes_max, do: @value_bytes_max

  @doc """
  Returns the filter that `raw` stands for under `spec`, or every violation
  in field order. One field yields at most one violation, that of the first
  value that breaks a rule.
  """
  @spec normalize(%{raw: raw(), spec: spec()}) :: {:ok, t()} | {:error, [violation(), ...]}
  def normalize(%{raw: raw, spec: spec}) when is_map(raw) and is_map(spec) do
    assert_spec(spec)

    if map_size(raw) <= @field_count_max do
      outcomes =
        for {field, raw_value} <- Enum.sort(raw), do: field_outcome(field, raw_value, spec)

      case for {:error, violation} <- outcomes, do: violation do
        [] ->
          {:ok, for({:ok, {field, [_ | _] = values}} <- outcomes, into: %{}, do: {field, values})}

        violations ->
          {:error, violations}
      end
    else
      {:error, [%{field: nil, reason: :too_many_fields}]}
    end
  end

  @doc """
  Whether a record whose fields hold `values` matches `filter`. `values`
  maps a field's name to the record's value, `nil` or absent for a record
  that has none.
  """
  @spec matches?(%{filter: t(), values: values()}) :: boolean()
  def matches?(%{filter: filter, values: values}) when is_map(filter) and is_map(values) do
    Enum.all?(filter, fn {field, accepted} ->
      Assert.condition(accepted != [], "filter field #{inspect(field)} must accept a value")

      case Map.get(values, field) do
        nil -> false
        value -> value in accepted
      end
    end)
  end

  defp assert_spec(spec) do
    Assert.condition(
      map_size(spec) <= @field_count_max,
      "specification must name at most #{@field_count_max} fields, got: #{map_size(spec)}"
    )

    Enum.each(spec, fn {field, type} ->
      Assert.condition(is_binary(field), "field name must be a string, got: #{inspect(field)}")
      Assert.condition(type == :string, "field type must be :string, got: #{inspect(type)}")
    end)
  end

  defp field_outcome(field, raw_value, spec) do
    Assert.condition(is_binary(field), "raw field name must be a string, got: #{inspect(field)}")

    case Map.fetch(spec, field) do
      :error ->
        {:error, %{field: field, reason: :unknown_field}}

      {:ok, :string} ->
        case string_values(raw_value) do
          {:ok, values} -> {:ok, {field, values}}
          {:error, reason} -> {:error, %{field: field, reason: reason}}
        end

      {:ok, type} ->
        Assert.unreachable(type)
    end
  end

  defp string_values(raw_value) when is_binary(raw_value), do: string_values([raw_value])

  defp string_values(raw_values) when is_list(raw_values) do
    if length(raw_values) <= @value_count_max do
      case Enum.find_value(raw_values, &value_violation/1) do
        nil -> {:ok, raw_values |> Enum.reject(&(&1 == "")) |> Enum.uniq() |> Enum.sort()}
        reason -> {:error, reason}
      end
    else
      {:error, :too_many_values}
    end
  end

  defp string_values(_raw_value), do: {:error, :invalid_value}

  defp value_violation(value) when is_binary(value) do
    cond do
      byte_size(value) > @value_bytes_max -> :value_too_long
      String.valid?(value) -> nil
      true -> :invalid_value
    end
  end

  defp value_violation(_value), do: :invalid_value
end
