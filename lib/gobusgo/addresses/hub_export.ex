defmodule Gobusgo.Addresses.HubExport do
  @redirect_hop_count_max 3
  @export_last_edit_header "x-ms-meta-lasteditdate"
  @export_record_count_header "x-ms-meta-recordcount"
  @redirect_statuses [301, 302, 303, 307, 308]

  @moduledoc """
  A county layer's one-file export from the ArcGIS Hub, checked against the
  layer before any of it is written. Read `lib/gobusgo/addresses/AGENTS.md`
  before changing it.

  `fetch/2` reads the layer's last edit and record count from its
  FeatureServer, asks the Hub for the export, follows the export's address
  and its redirects, and checks the export's own metadata, which the blob's
  `#{@export_last_edit_header}` and `#{@export_record_count_header}` headers
  carry, against the layer's before it writes any of the body: an export
  that is older than the layer or has another record count is `{:stale, _}`.
  A redirect is followed at most #{@redirect_hop_count_max} times and only
  to an `https` address under `arcgis.com`.

  The request names the item, the layer's FeatureServer address, the file
  the export is written to, the most bytes of it, and, optionally,
  `spatial_ref_id`, the well-known identifier of the coordinate system the
  export's coordinates are in, which the Hub's download API takes as
  `spatialRefId`.
  """

  alias Gobusgo.Addresses.ArcGis
  alias Gobusgo.Addresses.Http

  @type request :: %{
          required(:item_id) => String.t(),
          required(:layer_url) => String.t(),
          required(:path) => String.t(),
          required(:bytes_max) => pos_integer(),
          optional(:spatial_ref_id) => pos_integer()
        }

  @spec fetch(request(), keyword()) ::
          {:ok, Gobusgo.Addresses.Source.export()}
          | {:stale, Gobusgo.Addresses.Source.stale()}
          | {:error, term()}
  def fetch(
        %{item_id: item_id, layer_url: layer_url, path: path, bytes_max: bytes_max} = request,
        options
      )
      when is_list(options) do
    export_request =
      Map.merge(
        %{item_id: item_id, layer: 0, format: "csv"},
        Map.take(request, [:spatial_ref_id])
      )

    with {:ok, layer} <- ArcGis.layer_status(layer_url, options),
         {:ok, result_url} <- ArcGis.export_url(export_request, options),
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
end
