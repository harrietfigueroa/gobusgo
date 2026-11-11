defmodule Gobusgo.Addresses.ArcGis do
  @poll_count_max 18
  @poll_answer_statuses [200, 202]
  @poll_delay_ms 10_000
  @json_bytes_max 1_048_576
  @hub_host "hub.arcgis.com"
  @arcgis_host_suffix ".arcgis.com"

  @moduledoc """
  The two ArcGIS services a county's address export is read through. Read
  `lib/gobusgo/addresses/AGENTS.md` before changing it.

  `layer_status/2` reads a FeatureServer layer's last edit and its record
  count. `export_url/2` asks the ArcGIS Hub download API for a one-file
  export of a layer and polls it, at most #{@poll_count_max} times
  #{@poll_delay_ms} ms apart, until it names the address of the finished
  file. `redirect_target/1` accepts the address a redirect names only when it
  is an `https` address of a host under `#{@arcgis_host_suffix}`.

  Every outcome the services document is a value. Transport faults come back
  as `{:error, {:transport, reason}}` and a status or body the services do
  not document as `{:error, {:unexpected_status, status}}` or
  `{:error, {:malformed, path}}`.
  """

  alias Gobusgo.Addresses.Http
  alias Gobusgo.Schema

  @type layer_status :: %{last_edit_at: DateTime.t(), record_count: non_neg_integer()}

  @type error ::
          Http.error()
          | {:unexpected_status, pos_integer()}
          | {:malformed, String.t()}
          | :export_failed
          | :export_not_supported
          | :export_not_found
          | :export_not_ready
          | :layer_error

  @layer_schema {:map, %{"editingInfo" => {:map, %{"lastEditDate" => :integer}}}}
  @count_schema {:map, %{"count" => :integer}}
  @hub_schema {:map, %{"status" => :string, "resultUrl" => {:optional, :string}}}

  @doc """
  The last edit and the record count of the layer at `layer_url`, an `https`
  address of a FeatureServer layer.
  """
  @spec layer_status(String.t(), keyword()) :: {:ok, layer_status()} | {:error, error()}
  def layer_status(layer_url, options) when is_binary(layer_url) and is_list(options) do
    # https://developers.arcgis.com/rest/services-reference/enterprise/layer-feature-service/
    # (the layer's `editingInfo.lastEditDate`, milliseconds since the epoch)
    # and
    # https://developers.arcgis.com/rest/services-reference/enterprise/query-feature-service-layer/
    # (`returnCountOnly`) — checked 2026-11-10
    with {:ok, layer} <- get_json(layer_url <> "?f=json", @layer_schema, options),
         {:ok, count} <-
           get_json(
             layer_url <> "/query?where=1%3D1&returnCountOnly=true&f=json",
             @count_schema,
             options
           ),
         {:ok, last_edit_at} <-
           DateTime.from_unix(layer["editingInfo"]["lastEditDate"], :millisecond) do
      {:ok, %{last_edit_at: last_edit_at, record_count: count["count"]}}
    else
      {:error, :invalid_unix_time} -> {:error, {:malformed, "editingInfo.lastEditDate"}}
      {:error, _reason} = failure -> failure
    end
  end

  defp get_json(url, schema, options) do
    case Http.get_json(%{url: url, bytes_max: @json_bytes_max}, options) do
      {:ok, %{status: 200, body: body}} -> decode(body, schema)
      {:ok, %{status: status}} -> {:error, {:unexpected_status, status}}
      {:error, _reason} = failure -> failure
    end
  end

  defp decode(body, schema) do
    case JSON.decode(body) do
      {:ok, decoded} ->
        case Schema.mismatch(decoded, schema) do
          nil -> {:ok, decoded}
          %{path: path} -> {:error, {:malformed, Schema.format_path(path)}}
        end

      {:error, _reason} ->
        {:error, {:malformed, "root"}}
    end
  end

  @doc """
  The address of the finished export of layer `export.layer` of the item
  `export.item_id`, in `export.format`, which the Hub's download API at
  `https://#{@hub_host}/api/download/v1/items/<item>/<format>` has made.

  The API answers `200` with a JSON object whose `status` is `"Completed"`
  and whose `resultUrl` names the file once it is ready, another `status`
  while it is not, `202` with a `status` of `"Pending"` and the message
  "Up to date download file is being generated" while it makes a fresh file
  (about one poll in five on 2026-11-11), `400` for an item that cannot be
  downloaded, and `404` for a layer the item lacks. A `status` of
  `"Failed"` ends the wait. The contract is what the API answered on
  2026-11-10 and 2026-11-11; Esri has not published it.
  """
  @spec export_url(
          %{item_id: String.t(), layer: non_neg_integer(), format: String.t()},
          keyword()
        ) :: {:ok, String.t()} | {:error, error()}
  def export_url(%{item_id: item_id, layer: layer, format: format}, options)
      when is_binary(item_id) and is_integer(layer) and layer >= 0 and is_binary(format) and
             is_list(options) do
    url =
      "https://#{@hub_host}/api/download/v1/items/#{item_id}/#{format}?layers=#{layer}&redirect=false"

    poll_delay_ms = Keyword.get(options, :poll_delay_ms, @poll_delay_ms)
    poll(%{url: url, polls_left: @poll_count_max, poll_delay_ms: poll_delay_ms, options: options})
  end

  defp poll(%{polls_left: 0}), do: {:error, :export_not_ready}

  defp poll(%{url: url, options: options} = state) do
    case Http.get_json(%{url: url, bytes_max: @json_bytes_max}, options) do
      {:ok, %{status: status, body: body}} when status in @poll_answer_statuses ->
        poll_answer(body, state)

      {:ok, %{status: 400}} ->
        {:error, :export_not_supported}

      {:ok, %{status: 404}} ->
        {:error, :export_not_found}

      {:ok, %{status: status}} ->
        {:error, {:unexpected_status, status}}

      {:error, _reason} = failure ->
        failure
    end
  end

  defp poll_answer(body, state) do
    case decode(body, @hub_schema) do
      {:ok, %{"status" => "Completed", "resultUrl" => result_url}} ->
        {:ok, result_url}

      {:ok, %{"status" => "Failed"}} ->
        {:error, :export_failed}

      {:ok, %{"status" => _pending}} ->
        Process.sleep(state.poll_delay_ms)
        poll(%{state | polls_left: state.polls_left - 1})

      {:error, _reason} = failure ->
        failure
    end
  end

  @doc """
  `{:ok, url}` when `location` is an `https` address of a host under
  `#{@arcgis_host_suffix}`, and `:refused` otherwise, so a redirect never
  leaves the services the integration names.
  """
  @spec redirect_target(String.t() | nil) :: {:ok, String.t()} | :refused
  def redirect_target(location) when is_binary(location) do
    case URI.parse(location) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        if String.ends_with?(host, @arcgis_host_suffix), do: {:ok, location}, else: :refused

      _other ->
        :refused
    end
  end

  def redirect_target(nil), do: :refused
end
