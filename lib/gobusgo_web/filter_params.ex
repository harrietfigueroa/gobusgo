defmodule GobusgoWeb.FilterParams do
  @value_separator ","

  @moduledoc """
  Reads a raw filter out of decoded query parameters, for
  `Gobusgo.Filter.normalize/1` to judge, and writes a filter as a query
  string. Everything here is pure, and nothing here decides whether a
  filter is valid.

  A field of the filter is the query parameter of the same name, and its
  values are separated by `#{@value_separator}`: `agency=1,40` holds two
  values. A parameter that is no field of the specification is left out, so
  a page's other parameters never reach the filter. A parameter that is not
  a string goes into the raw filter as it is.

  A query string holds the fields in name order. A value that holds
  `#{@value_separator}` reads back as two values.
  """

  alias Gobusgo.Filter

  @doc "Returns the raw filter that `params` hold for the fields of `spec`."
  @spec raw(%{params: %{String.t() => term()}, spec: Filter.spec()}) :: Filter.raw()
  def raw(%{params: params, spec: spec}) when is_map(params) and is_map(spec) do
    for {field, _type} <- spec, is_map_key(params, field), into: %{} do
      {field, values(Map.fetch!(params, field))}
    end
  end

  @doc "Returns `filter` as a query string, empty for the empty filter."
  @spec query(Filter.t()) :: String.t()
  def query(filter) when is_map(filter) do
    filter
    |> Enum.sort()
    |> Enum.map_join("&", fn {field, values} ->
      URI.encode_www_form(field) <>
        "=" <> Enum.map_join(values, @value_separator, &URI.encode_www_form/1)
    end)
  end

  defp values(value) when is_binary(value), do: String.split(value, @value_separator)
  defp values(value), do: value
end
