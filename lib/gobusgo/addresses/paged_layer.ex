defmodule Gobusgo.Addresses.PagedLayer do
  @moduledoc """
  A county's whole FeatureServer layer, paged with
  `Gobusgo.Addresses.FeaturePages` into a CSV file the build reads with
  `Gobusgo.Addresses.Csv`. Read `lib/gobusgo/addresses/AGENTS.md` before
  changing it.

  `fetch/2` reads the layer's last edit and count, writes a header of
  `request.columns`, then one row per feature, the row `request.row` makes
  of it, at most `request.bytes_max` bytes in all. A layer that holds more
  or fewer features than its count said when the read began, because the
  county edited it meanwhile, is `{:error, {:record_count_differs, read,
  layer}}`, and the scheduler's backoff reads it again. The file's last edit
  is the layer's, and paging reads the layer itself, so its result is never
  stale.

  The file is CSV, the form the Hub's exports take, because the build reads
  it in a process that sweeps its whole heap at every collection, and
  reading a CSV row allocates little garbage over a heap that holds the
  other counties' streets.
  """

  alias Gobusgo.Addresses.ArcGis
  alias Gobusgo.Addresses.Csv
  alias Gobusgo.Addresses.FeaturePages

  @type request :: %{
          layer_url: String.t(),
          path: String.t(),
          bytes_max: pos_integer(),
          out_fields: [String.t(), ...],
          columns: [String.t(), ...],
          row: (FeaturePages.feature() -> [binary()]),
          page_count_max: pos_integer()
        }

  @doc """
  Pages the layer of `request` into `request.path`. Answers the export the
  `Gobusgo.Addresses.Source` contract names, or `{:error, reason}`.
  Options are those of `Gobusgo.Addresses.ArcGis.layer_status/2` and
  `Gobusgo.Addresses.FeaturePages.stream/2`.
  """
  @spec fetch(request(), keyword()) :: {:ok, map()} | {:error, term()}
  def fetch(%{layer_url: layer_url, path: path} = request, options) when is_list(options) do
    with {:ok, layer} <- ArcGis.layer_status(layer_url, options),
         {:ok, written} <- write_pages(request, options),
         :ok <- count_unchanged(written.feature_count, layer.record_count) do
      {:ok,
       %{
         path: path,
         last_edit_at: layer.last_edit_at,
         record_count: written.feature_count,
         byte_count: written.byte_count
       }}
    end
  end

  @doc "The text of an attribute: a string as it is, an integer in decimal, and anything else empty."
  @spec attribute_text(%{String.t() => term()}, String.t()) :: binary()
  def attribute_text(attributes, field) when is_map(attributes) and is_binary(field) do
    case Map.get(attributes, field) do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      _absent -> ""
    end
  end

  @doc ~s(The text of a feature's coordinate on `axis`, `"x"` or `"y"`, or empty with no geometry.)
  @spec coordinate_text(FeaturePages.feature(), String.t()) :: binary()
  def coordinate_text(%{"geometry" => %{} = geometry}, axis) when axis in ["x", "y"] do
    case Map.get(geometry, axis) do
      value when is_float(value) -> Float.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _absent -> ""
    end
  end

  def coordinate_text(_feature, axis) when axis in ["x", "y"], do: ""

  defp count_unchanged(count, count), do: :ok

  defp count_unchanged(read_count, layer_count),
    do: {:error, {:record_count_differs, read_count, layer_count}}

  defp write_pages(request, options) do
    pages =
      FeaturePages.stream(
        %{
          url: request.layer_url <> "/query",
          out_fields: request.out_fields,
          page_count_max: request.page_count_max
        },
        options
      )

    device = File.open!(request.path, [:write, :binary])

    try do
      header = Csv.encode_row(request.columns)
      :ok = IO.binwrite(device, header)
      start = %{feature_count: 0, byte_count: IO.iodata_length(header)}
      writing = %{device: device, row: request.row, bytes_max: request.bytes_max}

      pages
      |> Enum.reduce_while(start, fn
        {:page, features}, written -> write_page(features, written, writing)
        {:error, _reason} = failure, _written -> {:halt, failure}
      end)
      |> finished()
    after
      File.close(device)
    end
  end

  defp finished({:error, _reason} = failure), do: failure
  defp finished(written), do: {:ok, written}

  defp write_page(features, written, %{device: device, row: row, bytes_max: bytes_max}) do
    rows = Enum.map(features, &(&1 |> row.() |> Csv.encode_row()))
    page_bytes = IO.iodata_length(rows)
    total_bytes = written.byte_count + page_bytes

    if total_bytes <= bytes_max do
      :ok = IO.binwrite(device, rows)
      {:cont, %{feature_count: written.feature_count + length(features), byte_count: total_bytes}}
    else
      {:halt, {:error, :body_too_large}}
    end
  end
end
