defmodule Gobusgo.Addresses.Source.King do
  @item_id "5aa0a3c77428491da8d73e9d069c10f6"
  @layer_url "https://services.arcgis.com/Ej0PsM5Aw677QF1W/arcgis/rest/services/ADDRESS_POINT_642/FeatureServer/0"
  @export_file_name "king-addresses.csv"
  @redirect_hop_count_max 3
  @read_bytes 65_536
  @export_last_edit_header "x-ms-meta-lasteditdate"
  @export_record_count_header "x-ms-meta-recordcount"
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
  county's open data portal, as the one-file CSV export of the ArcGIS Hub.
  Read `lib/gobusgo/addresses/AGENTS.md` before changing it.

  The export's rows carry the position as `LAT` and `LON` in WGS 84, so the
  server needs no projection. A house number may hold a letter after a space
  (`"920 B"`).

  `fetch/2` reads the layer's last edit and record count from its
  FeatureServer, asks the Hub for the export, follows the export's address
  and its redirects, and checks the export's own metadata, which the blob's
  `#{@export_last_edit_header}` and `#{@export_record_count_header}` headers
  carry, against the layer's before it writes any of the body: an export
  that is older than the layer or has another record count is `{:stale, _}`.
  A redirect is followed at most #{@redirect_hop_count_max} times and only
  to an `https` address under `arcgis.com`.
  """

  @behaviour Gobusgo.Addresses.Source

  alias Gobusgo.Addresses.ArcGis
  alias Gobusgo.Addresses.Csv
  alias Gobusgo.Addresses.Http

  @redirect_statuses [301, 302, 303, 307, 308]

  @impl Gobusgo.Addresses.Source
  def name, do: :king

  @impl Gobusgo.Addresses.Source
  def fetch(%{directory: directory, bytes_max: bytes_max}, options) when is_list(options) do
    layer_url = Keyword.get(options, :layer_url, @layer_url)
    path = Path.join(directory, @export_file_name)

    with {:ok, layer} <- ArcGis.layer_status(layer_url, options),
         {:ok, result_url} <-
           ArcGis.export_url(%{item_id: @item_id, layer: 0, format: "csv"}, options),
         {:ok, export_url} <- allowed(result_url) do
      download(%{
        url: export_url,
        path: path,
        bytes_max: bytes_max,
        layer: layer,
        hops_left: @redirect_hop_count_max,
        options: options
      })
    end
  end

  defp allowed(url) do
    case ArcGis.redirect_target(url) do
      {:ok, url} -> {:ok, url}
      :refused -> {:error, :address_refused}
    end
  end

  defp download(%{hops_left: hops_left}) when hops_left < 0, do: {:error, :too_many_redirects}

  defp download(%{layer: layer} = state) do
    request = %{
      url: state.url,
      path: state.path,
      bytes_max: state.bytes_max,
      inspect_headers: &inspect_export(&1, layer)
    }

    case Http.get_to_file(request, state.options) do
      {:ok, %{status: 200, byte_count: byte_count}} ->
        {:ok,
         %{
           path: state.path,
           last_edit_at: layer.last_edit_at,
           record_count: layer.record_count,
           byte_count: byte_count
         }}

      {:ok, %{status: status, location: location}} when status in @redirect_statuses ->
        follow(location, state)

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:halted, details} ->
        {:stale, details}

      {:error, _reason} = failure ->
        failure
    end
  end

  defp follow(location, state) do
    case allowed(location) do
      {:ok, url} -> download(%{state | url: url, hops_left: state.hops_left - 1})
      {:error, _reason} = refused -> refused
    end
  end

  # The export's headers say when the layer was last edited when it was
  # exported and how many records it holds.
  # https://learn.microsoft.com/en-us/rest/api/storageservices/get-blob-properties
  # (user-defined metadata is returned as `x-ms-meta-*` headers) — checked
  # 2026-11-10
  defp inspect_export(headers, layer) do
    with {:ok, last_edit_ms} <- integer_header(headers, @export_last_edit_header),
         {:ok, record_count} <- integer_header(headers, @export_record_count_header),
         {:ok, export_last_edit_at} <- DateTime.from_unix(last_edit_ms, :millisecond) do
      is_current = DateTime.compare(export_last_edit_at, layer.last_edit_at) != :lt
      has_count = record_count == layer.record_count

      cond do
        not is_current -> {:halt, stale(:export_older_than_layer, layer)}
        not has_count -> {:halt, stale(:record_count_differs, layer)}
        true -> :ok
      end
    else
      _missing -> {:halt, stale(:export_metadata_missing, layer)}
    end
  end

  defp stale(reason, layer) do
    %{
      reason: reason,
      layer_last_edit_at: layer.last_edit_at,
      layer_record_count: layer.record_count
    }
  end

  defp integer_header(headers, name) do
    with [value | _rest] <- Map.get(headers, name, []),
         {integer, ""} <- Integer.parse(value) do
      {:ok, integer}
    else
      _missing -> :error
    end
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
