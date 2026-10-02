defmodule Gobusgo.Assert do
  @moduledoc """
  Assertions for programmer errors and for payloads that violate a boundary
  contract. Every failure raises `Gobusgo.Assert.AssertionError`, so a crash
  from any helper is recognizable as a bug rather than an operating error.
  Everything here is pure.
  """

  defmodule AssertionError do
    @moduledoc "Raised by every assertion in `Gobusgo.Assert`."
    defexception [:message, :cause]

    @type t :: %__MODULE__{message: String.t(), cause: map() | nil}
  end

  @type schema ::
          :string
          | :number
          | :integer
          | :boolean
          | {:literal, term()}
          | {:list, schema()}
          | {:map, %{optional(String.t()) => schema()}}

  @doc """
  Raises `AssertionError` with `message` unless `condition` is truthy. The
  message carries the operand values, so a failure names what broke.
  """
  @spec condition(as_boolean(term()), String.t()) :: :ok
  def condition(condition, message) when is_binary(message) do
    if condition do
      :ok
    else
      raise AssertionError, message: message
    end
  end

  @doc """
  Returns `value` when it matches `schema`; otherwise raises `AssertionError`
  whose `cause` holds the path and the expected shape of the first mismatch.
  Map schemas require their keys and ignore unknown ones. The message and the
  cause never contain the offending value, so a payload cannot leak through a
  failed assertion.
  """
  @spec schema(term(), schema()) :: term()
  def schema(value, schema) do
    case mismatch(value, schema, []) do
      nil ->
        value

      %{path: path} = cause ->
        raise AssertionError,
          message: "schema mismatch at #{format_path(path)}",
          cause: cause
    end
  end

  defp format_path([]), do: "root"
  defp format_path(path), do: Enum.map_join(path, ".", &to_string/1)

  defp mismatch(value, :string, path), do: unless(is_binary(value), do: failure(path, :string))
  defp mismatch(value, :number, path), do: unless(is_number(value), do: failure(path, :number))
  defp mismatch(value, :integer, path), do: unless(is_integer(value), do: failure(path, :integer))
  defp mismatch(value, :boolean, path), do: unless(is_boolean(value), do: failure(path, :boolean))

  defp mismatch(value, {:literal, expected}, path) do
    unless value === expected, do: failure(path, {:literal, expected})
  end

  defp mismatch(value, {:list, element_schema}, path) when is_list(value) do
    value
    |> Enum.with_index()
    |> Enum.find_value(fn {element, index} ->
      mismatch(element, element_schema, path ++ [index])
    end)
  end

  defp mismatch(value, {:map, fields}, path) when is_map(value) do
    Enum.find_value(fields, fn {key, field_schema} ->
      case Map.fetch(value, key) do
        {:ok, field} -> mismatch(field, field_schema, path ++ [key])
        :error -> failure(path ++ [key], :required)
      end
    end)
  end

  defp mismatch(_value, schema, path), do: failure(path, schema)

  defp failure(path, expected), do: %{path: path, expected: expected}
end
