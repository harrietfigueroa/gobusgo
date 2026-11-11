defmodule Gobusgo.Addresses.Source.King do
  @item_id "5aa0a3c77428491da8d73e9d069c10f6"
  @layer_url "https://services.arcgis.com/Ej0PsM5Aw677QF1W/arcgis/rest/services/ADDRESS_POINT_642/FeatureServer/0"
  @export_file_name "king-addresses.csv"
  @read_bytes 65_536
  @columns %{
    house_number: "HouseNum",
    pre_direction: "PreDir",
    name: "StreetName",
    type: "SufType",
    suf_direction: "SufDir",
    city: "POSTALCTYNAME",
    lat: "LAT",
    lon: "LON"
  }

  @moduledoc """
  King County's "Addresses in King County" layer, item `#{@item_id}` of the
  county's open data portal, as the one-file CSV export of the ArcGIS Hub
  (`Gobusgo.Addresses.HubExport`). Read `lib/gobusgo/addresses/AGENTS.md`
  before changing it.

  The export's rows carry the position as `LAT` and `LON` in WGS 84, so the
  server needs no projection. A house number may hold a letter after a space
  (`"920 B"`).
  """

  @behaviour Gobusgo.Addresses.Source

  alias Gobusgo.Addresses.Csv
  alias Gobusgo.Addresses.HubExport

  @impl Gobusgo.Addresses.Source
  def name, do: :king

  @impl Gobusgo.Addresses.Source
  def fetch(%{directory: directory, bytes_max: bytes_max}, options) when is_list(options) do
    HubExport.fetch(
      %{
        item_id: @item_id,
        layer_url: Keyword.get(options, :layer_url, @layer_url),
        path: Path.join(directory, @export_file_name),
        bytes_max: bytes_max
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
      lon: degrees(fields, indexes.lon)
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
