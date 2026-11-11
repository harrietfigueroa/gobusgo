defmodule Gobusgo.Addresses.FeaturePages do
  @page_size 100
  @record_count_max 2_000_000
  @transient_statuses [408, 429]
  @server_error_statuses 500..599
  @order_field "OBJECTID"
  @wgs84_wkid 4326

  @moduledoc """
  The rules of reading a FeatureServer layer in pages of #{@page_size}
  records. Read `lib/gobusgo/addresses/AGENTS.md` before changing it.

  Everything here is pure: the offsets of a layer's pages, the query of one
  page, the reading of the page the service answers, which failures are
  transient, and the delay before a retry. `Gobusgo.Addresses.ArcGis.pages/2`
  makes the requests.

  A page is asked for by `resultOffset` and `resultRecordCount`, ordered by
  `#{@order_field}`, with the positions in WGS 84 (`outSR=#{@wgs84_wkid}`),
  so the records of one count, read at every offset, are each read once.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Schema

  @type feature :: %{
          attributes: %{String.t() => String.t() | nil},
          lat: float() | nil,
          lon: float() | nil
        }

  @type error ::
          {:service_error, integer()}
          | {:malformed, String.t()}
          | {:page_too_large, pos_integer()}

  @error_schema {:map, %{"error" => {:map, %{"code" => :integer}}}}
  @geometry_schema {:optional, {:nullable, {:map, %{"x" => :number, "y" => :number}}}}

  @doc "The most records one request asks for."
  @spec page_size() :: pos_integer()
  def page_size, do: @page_size

  @doc "The most records a layer may report, which bounds the pages of a run."
  @spec record_count_max() :: pos_integer()
  def record_count_max, do: @record_count_max

  @doc """
  The offsets of the pages that hold `record_count` records, the first 0 and
  each #{@page_size} after the one before it, or
  `{:error, {:record_count_too_large, record_count}}` past
  #{@record_count_max} records.
  """
  @spec offsets(non_neg_integer()) ::
          {:ok, Enumerable.t(non_neg_integer())}
          | {:error, {:record_count_too_large, pos_integer()}}
  def offsets(record_count) when is_integer(record_count) and record_count >= 0 do
    if record_count <= @record_count_max do
      {:ok, Range.new(0, record_count - 1, @page_size)}
    else
      {:error, {:record_count_too_large, record_count}}
    end
  end

  @doc """
  The address of the page at `query.offset` of the layer at
  `query.layer_url`, holding the fields `query.out_fields` and each record's
  point.
  """
  @spec query_url(%{layer_url: String.t(), out_fields: [String.t()], offset: non_neg_integer()}) ::
          String.t()
  def query_url(%{
        layer_url: layer_url,
        out_fields: [_field | _rest] = out_fields,
        offset: offset
      })
      when is_binary(layer_url) and is_integer(offset) and offset >= 0 do
    # https://developers.arcgis.com/rest/services-reference/enterprise/query-feature-service-layer/
    # (`resultOffset`, `resultRecordCount` up to the layer's `maxRecordCount`,
    # `orderByFields`, `outFields`, `returnGeometry`, `outSR`) — checked
    # 2026-11-11
    query =
      URI.encode_query(
        [
          {"where", "1=1"},
          {"outFields", Enum.join(out_fields, ",")},
          {"returnGeometry", "true"},
          {"outSR", Integer.to_string(@wgs84_wkid)},
          {"orderByFields", @order_field},
          {"resultOffset", Integer.to_string(offset)},
          {"resultRecordCount", Integer.to_string(@page_size)},
          {"f", "json"}
        ],
        :rfc3986
      )

    layer_url <> "/query?" <> query
  end

  @doc """
  The features of a page's JSON `body`, in the order the service sent them,
  each with the fields `out_fields` as text or `nil` and its point's
  latitude and longitude, `nil` for a feature with no point.

  The service answers a failed query with `200` and a body of
  `{"error": {"code": code}}`, which is `{:error, {:service_error, code}}`.
  """
  @spec decode_page(binary(), [String.t()]) :: {:ok, [feature()]} | {:error, error()}
  def decode_page(body, [_field | _rest] = out_fields) when is_binary(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> page(decoded, out_fields)
      {:error, _reason} -> {:error, {:malformed, "root"}}
    end
  end

  defp page(decoded, out_fields) do
    attributes_schema = {:map, Map.new(out_fields, &{&1, {:optional, {:nullable, :string}}})}

    page_schema =
      {:map,
       %{
         "features" =>
           {:list, {:map, %{"attributes" => attributes_schema, "geometry" => @geometry_schema}}}
       }}

    cond do
      Schema.mismatch(decoded, @error_schema) == nil ->
        {:error, {:service_error, decoded["error"]["code"]}}

      (mismatch = Schema.mismatch(decoded, page_schema)) != nil ->
        {:error, {:malformed, Schema.format_path(mismatch.path)}}

      length(decoded["features"]) > @page_size ->
        {:error, {:page_too_large, length(decoded["features"])}}

      true ->
        {:ok, Enum.map(decoded["features"], &feature(&1, out_fields))}
    end
  end

  defp feature(%{"attributes" => attributes} = decoded, out_fields) do
    point = Map.get(decoded, "geometry")
    fields = Map.new(out_fields, &{&1, Map.get(attributes, &1)})

    case point do
      %{"x" => x, "y" => y} -> %{attributes: fields, lat: y / 1, lon: x / 1}
      nil -> %{attributes: fields, lat: nil, lon: nil}
    end
  end

  @doc """
  Whether a failure is transient and the request is asked for again: a
  network fault, a deadline, and the statuses 408, 429, and 5xx, whether as
  the response's status or as the code of the service's error object.
  """
  @spec transient?(term()) :: boolean()
  def transient?({:unexpected_status, status}), do: transient_status?(status)
  def transient?({:service_error, code}), do: transient_status?(code)
  def transient?({:transport, _reason}), do: true
  def transient?(:deadline_exceeded), do: true
  def transient?(_failure), do: false

  defp transient_status?(status),
    do: status in @transient_statuses or status in @server_error_statuses

  @doc """
  The delay before the retry that follows attempt `attempt_index`, counted
  from 0: `base_ms` doubled for each attempt up to `cap_ms`, times `jitter`,
  a share from 0 to 1. A `retry_after_ms` the service sent replaces it, up to
  `cap_ms`.
  """
  @spec retry_delay_ms(%{
          attempt_index: non_neg_integer(),
          base_ms: non_neg_integer(),
          cap_ms: non_neg_integer(),
          retry_after_ms: non_neg_integer() | nil,
          jitter: float()
        }) :: non_neg_integer()
  def retry_delay_ms(%{attempt_index: attempt_index, cap_ms: cap_ms} = delay)
      when is_integer(attempt_index) and attempt_index >= 0 do
    Assert.condition(delay.jitter >= 0.0, "jitter must be at least 0, got: #{delay.jitter}")
    Assert.condition(delay.jitter <= 1.0, "jitter must be at most 1, got: #{delay.jitter}")

    case delay.retry_after_ms do
      nil ->
        doubled_ms = min(delay.base_ms * Integer.pow(2, attempt_index), cap_ms)
        trunc(doubled_ms * delay.jitter)

      retry_after_ms ->
        min(retry_after_ms, cap_ms)
    end
  end

  @doc """
  The milliseconds a `Retry-After` header of whole seconds names, or `nil`
  for no header or another form.
  """
  @spec retry_after_ms(String.t() | nil) :: non_neg_integer() | nil
  def retry_after_ms(nil), do: nil

  def retry_after_ms(header) when is_binary(header) do
    case Integer.parse(header) do
      {seconds, ""} when seconds >= 0 -> seconds * 1_000
      _other -> nil
    end
  end
end
