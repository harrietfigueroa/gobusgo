defmodule Gobusgo.Addresses.Source.Snohomish do
  @item_id "3c07edee19f142d2926dc1f7e4efc474"
  @layer_url "https://services6.arcgis.com/z6WYi9VRHfgwgtyW/arcgis/rest/services/Building_Address_Points/FeatureServer/0"
  @file_name "snohomish-addresses.csv"
  @read_bytes 65_536
  @page_count_max 5_000
  @out_fields [
    "OBJECTID",
    "Add_Number",
    "AddNum_Suf",
    "LSt_PreDir",
    "LSt_Name",
    "LSt_Type",
    "LSt_PostDir",
    "Post_Comm"
  ]
  @columns [
    "Add_Number",
    "AddNum_Suf",
    "LSt_PreDir",
    "LSt_Name",
    "LSt_Type",
    "LSt_PostDir",
    "Post_Comm",
    "x",
    "y"
  ]

  @moduledoc """
  Snohomish County's "Building Address Points" layer, item `#{@item_id}` of
  the county's open data portal, read by paging its FeatureServer
  (`Gobusgo.Addresses.FeaturePages`), not through the Hub's CSV export,
  which answered from a stale copy (GOB-354). Read
  `lib/gobusgo/addresses/AGENTS.md` before changing it.

  The layer's `Lat` and `Long` fields are blank or in another projection for
  27% of its rows, so the position is the feature's geometry, which the
  query asks for in WGS 84. The street is the `LSt_*` fields, the county's
  short spelling, and the postal city is `Post_Comm`. A house number is
  `Add_Number`, and `AddNum_Suf`, when there is one, follows it after a
  space.

  `fetch/2` reads the layer's last edit and count, then writes each page's
  features to a CSV file of the columns above, `x` the longitude and `y`
  the latitude, at most `request.bytes_max` bytes of it and at most
  #{@page_count_max} pages. The build reads that file with
  `Gobusgo.Addresses.Csv`, as it reads the Hub exports, so reading a county
  allocates the same small amount of garbage whichever way it was fetched.
  A layer that holds more or fewer features than its count said when the
  read began, because the county edited it meanwhile, is an error, and the
  scheduler's backoff reads it again. The export's last edit is the layer's.
  Paging reads the layer itself, so no export is ever stale.
  """

  @behaviour Gobusgo.Addresses.Source

  alias Gobusgo.Addresses.ArcGis
  alias Gobusgo.Addresses.Csv
  alias Gobusgo.Addresses.FeaturePages

  @impl Gobusgo.Addresses.Source
  def name, do: :snohomish

  @impl Gobusgo.Addresses.Source
  def fetch(%{directory: directory, bytes_max: bytes_max}, options) when is_list(options) do
    layer_url = Keyword.get(options, :layer_url, @layer_url)
    path = Path.join(directory, @file_name)

    with {:ok, layer} <- ArcGis.layer_status(layer_url, options),
         {:ok, written} <-
           write_pages(%{url: layer_url, path: path, bytes_max: bytes_max}, options),
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

  defp count_unchanged(count, count), do: :ok

  defp count_unchanged(read_count, layer_count),
    do: {:error, {:record_count_differs, read_count, layer_count}}

  defp write_pages(%{url: url, path: path, bytes_max: bytes_max}, options) do
    pages =
      FeaturePages.stream(
        %{url: url <> "/query", out_fields: @out_fields, page_count_max: @page_count_max},
        options
      )

    device = File.open!(path, [:write, :binary])

    try do
      header = Csv.encode_row(@columns)
      :ok = IO.binwrite(device, header)
      start = %{feature_count: 0, byte_count: IO.iodata_length(header)}

      pages
      |> Enum.reduce_while(start, fn
        {:page, features}, written ->
          write_page(features, %{device: device, written: written, bytes_max: bytes_max})

        {:error, _reason} = failure, _written ->
          {:halt, failure}
      end)
      |> finished()
    after
      File.close(device)
    end
  end

  defp finished({:error, _reason} = failure), do: failure
  defp finished(written), do: {:ok, written}

  defp write_page(features, %{device: device, written: written, bytes_max: bytes_max}) do
    rows = Enum.map(features, &(&1 |> row() |> Csv.encode_row()))
    page_bytes = IO.iodata_length(rows)

    if written.byte_count + page_bytes <= bytes_max do
      :ok = IO.binwrite(device, rows)

      {:cont,
       %{
         feature_count: written.feature_count + length(features),
         byte_count: written.byte_count + page_bytes
       }}
    else
      {:halt, {:error, :body_too_large}}
    end
  end

  defp row(%{"attributes" => attributes} = feature) do
    [
      text(attributes, "Add_Number"),
      text(attributes, "AddNum_Suf"),
      text(attributes, "LSt_PreDir"),
      text(attributes, "LSt_Name"),
      text(attributes, "LSt_Type"),
      text(attributes, "LSt_PostDir"),
      text(attributes, "Post_Comm"),
      degrees(feature, "x"),
      degrees(feature, "y")
    ]
  end

  defp text(attributes, field) do
    case Map.get(attributes, field) do
      value when is_binary(value) -> value
      value when is_integer(value) -> Integer.to_string(value)
      _absent -> ""
    end
  end

  defp degrees(%{"geometry" => %{} = geometry}, axis) do
    case Map.get(geometry, axis) do
      value when is_float(value) -> Float.to_string(value)
      value when is_integer(value) -> Integer.to_string(value)
      _absent -> ""
    end
  end

  defp degrees(_feature, _axis), do: ""

  @impl Gobusgo.Addresses.Source
  def records(path) when is_binary(path) do
    rows = path |> File.stream!(@read_bytes) |> Csv.rows()

    Stream.transform(rows, :header, fn
      header, :header -> {[], column_indexes(header)}
      row, indexes -> {[record(row, indexes)], indexes}
    end)
  end

  defp column_indexes(header) do
    positions = header |> Enum.with_index() |> Map.new()

    Map.new(@columns, fn column ->
      case Map.fetch(positions, column) do
        {:ok, index} ->
          {column, index}

        :error ->
          raise Gobusgo.Assert.AssertionError, message: "the file has no #{column} column"
      end
    end)
  end

  defp record(row, indexes) do
    fields = List.to_tuple(row)

    %{
      house_number: house_number(fields, indexes),
      pre_direction: field(fields, indexes["LSt_PreDir"]),
      name: field(fields, indexes["LSt_Name"]),
      type: field(fields, indexes["LSt_Type"]),
      suf_direction: field(fields, indexes["LSt_PostDir"]),
      city: field(fields, indexes["Post_Comm"]),
      lat: coordinate(fields, indexes["y"]),
      lon: coordinate(fields, indexes["x"])
    }
  end

  defp house_number(fields, indexes) do
    number = field(fields, indexes["Add_Number"])

    case field(fields, indexes["AddNum_Suf"]) do
      "" -> number
      suffix -> number <> " " <> suffix
    end
  end

  defp field(fields, index) when index < tuple_size(fields), do: elem(fields, index)
  defp field(_fields, _index), do: ""

  defp coordinate(fields, index) do
    case Float.parse(field(fields, index)) do
      {degrees, ""} -> degrees
      _other -> nil
    end
  end
end
