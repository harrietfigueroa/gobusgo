defmodule Gobusgo.Addresses.Source.Pierce do
  @item_id "c8361c8247da4430922e4439da8513c8"
  @layer_url "https://services2.arcgis.com/1UvBaQ5y1ubjUPmd/arcgis/rest/services/Address_Points/FeatureServer/0"
  @export_file_name "pierce-addresses.csv"
  @read_bytes 65_536
  @wgs84_spatial_ref_id 4326
  @active_status "ACTIVE"
  @columns %{
    house_number: "HouseNumber",
    pre_direction: "PrefixDirectional",
    name: "StreetName",
    type: "StreetType",
    suf_direction: "PostDirectional",
    city: "City",
    status: "Status",
    lon: "x",
    lat: "y"
  }

  @moduledoc """
  Pierce County's "Address_Points" layer, item `#{@item_id}` of the county's
  open geospatial data portal, as the one-file CSV export of the ArcGIS Hub
  (`Gobusgo.Addresses.HubExport`). Read `lib/gobusgo/addresses/AGENTS.md`
  before changing it.

  The layer is in State Plane South (EPSG 2927). The export is asked for in
  WGS 84 (`spatialRefId=#{@wgs84_spatial_ref_id}`), where the Hub writes
  the longitude and latitude in the `x` and `y` columns, so the server needs
  no projection.

  A record whose `Status` is `#{@active_status}` is an address. Any other
  status, which the county gives to a temporary point on a vacant parcel, is
  read with `is_active: false`, so the accumulator counts it and leaves it
  out, and the count of records read stays the layer's.
  """

  @behaviour Gobusgo.Addresses.Source

  alias Gobusgo.Addresses.Csv
  alias Gobusgo.Addresses.HubExport

  @impl Gobusgo.Addresses.Source
  def name, do: :pierce

  @impl Gobusgo.Addresses.Source
  def fetch(%{directory: directory, bytes_max: bytes_max}, options) when is_list(options) do
    HubExport.fetch(
      %{
        item_id: @item_id,
        layer_url: Keyword.get(options, :layer_url, @layer_url),
        path: Path.join(directory, @export_file_name),
        bytes_max: bytes_max,
        spatial_ref_id: @wgs84_spatial_ref_id
      },
      options
    )
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

    Map.new(@columns, fn {field, column} ->
      case Map.fetch(positions, column) do
        {:ok, index} ->
          {field, index}

        :error ->
          raise Gobusgo.Assert.AssertionError, message: "the export has no #{column} column"
      end
    end)
  end

  defp record(row, indexes) do
    fields = List.to_tuple(row)

    %{
      house_number: text(fields, indexes.house_number),
      pre_direction: text(fields, indexes.pre_direction),
      name: text(fields, indexes.name),
      type: text(fields, indexes.type),
      suf_direction: text(fields, indexes.suf_direction),
      city: text(fields, indexes.city),
      lat: degrees(fields, indexes.lat),
      lon: degrees(fields, indexes.lon),
      is_active: text(fields, indexes.status) == @active_status
    }
  end

  defp text(fields, index) when index < tuple_size(fields), do: elem(fields, index)
  defp text(_fields, _index), do: ""

  defp degrees(fields, index) do
    case Float.parse(text(fields, index)) do
      {degrees, ""} -> degrees
      _other -> nil
    end
  end
end
