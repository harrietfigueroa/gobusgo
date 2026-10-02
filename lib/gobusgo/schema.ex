defmodule Gobusgo.Schema do
  @moduledoc """
  A structural check of decoded data against a schema, with the first mismatch
  returned as a value. Everything here is pure.

  Map schemas require their keys and ignore unknown ones. A nullable schema
  matches `nil` and whatever its inner schema matches. A mismatch holds the
  path to the offending value and the shape expected there, and never the
  value itself, so a payload cannot leak through a reported mismatch.
  """

  @type t ::
          :string
          | :number
          | :integer
          | :boolean
          | {:literal, term()}
          | {:nullable, t()}
          | {:list, t()}
          | {:map, %{optional(String.t()) => t()}}

  @type path :: [String.t() | non_neg_integer()]
  @type mismatch :: %{path: path(), expected: t() | :required}

  @doc "Returns the first mismatch between `value` and `schema`, or `nil` when it matches."
  @spec mismatch(term(), t()) :: mismatch() | nil
  def mismatch(value, schema), do: mismatch(value, schema, [])

  @doc "Renders a mismatch path as dot-separated keys and indexes, `root` when empty."
  @spec format_path(path()) :: String.t()
  def format_path([]), do: "root"
  def format_path(path) when is_list(path), do: Enum.map_join(path, ".", &to_string/1)

  defp mismatch(value, :string, path), do: if(!is_binary(value), do: failure(path, :string))
  defp mismatch(value, :number, path), do: if(!is_number(value), do: failure(path, :number))
  defp mismatch(value, :integer, path), do: if(!is_integer(value), do: failure(path, :integer))
  defp mismatch(value, :boolean, path), do: if(!is_boolean(value), do: failure(path, :boolean))

  defp mismatch(value, {:literal, expected}, path) do
    if value !== expected, do: failure(path, {:literal, expected})
  end

  defp mismatch(nil, {:nullable, _inner_schema}, _path), do: nil
  defp mismatch(value, {:nullable, inner_schema}, path), do: mismatch(value, inner_schema, path)

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
