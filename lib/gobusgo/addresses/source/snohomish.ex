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

  `fetch/2` pages the layer with `Gobusgo.Addresses.PagedLayer` into a CSV
  file of the columns above, `x` the longitude and `y` the latitude, at
  most #{@page_count_max} pages.
  """

  @behaviour Gobusgo.Addresses.Source

  alias Gobusgo.Addresses.Csv
  alias Gobusgo.Addresses.PagedLayer

  @impl Gobusgo.Addresses.Source
  def name, do: :snohomish

  @impl Gobusgo.Addresses.Source
  def fetch(%{directory: directory, bytes_max: bytes_max}, options) when is_list(options) do
    PagedLayer.fetch(
      %{
        layer_url: Keyword.get(options, :layer_url, @layer_url),
        path: Path.join(directory, @file_name),
        bytes_max: bytes_max,
        out_fields: @out_fields,
        columns: @columns,
        row: &row/1,
        page_count_max: @page_count_max
      },
      options
    )
  end

  defp row(%{"attributes" => attributes} = feature) do
    [
      PagedLayer.attribute_text(attributes, "Add_Number"),
      PagedLayer.attribute_text(attributes, "AddNum_Suf"),
      PagedLayer.attribute_text(attributes, "LSt_PreDir"),
      PagedLayer.attribute_text(attributes, "LSt_Name"),
      PagedLayer.attribute_text(attributes, "LSt_Type"),
      PagedLayer.attribute_text(attributes, "LSt_PostDir"),
      PagedLayer.attribute_text(attributes, "Post_Comm"),
      PagedLayer.coordinate_text(feature, "x"),
      PagedLayer.coordinate_text(feature, "y")
    ]
  end

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
