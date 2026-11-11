defmodule Gobusgo.Addresses.ArcGis do
  @json_bytes_max 1_048_576
  @request_interval_ms 250
  @concurrency_max 4
  @attempt_count_max 4
  @retry_base_ms 1_000
  @retry_cap_ms 16_000

  @moduledoc """
  The FeatureServer requests a county's address points are read through.
  Read `lib/gobusgo/addresses/AGENTS.md` before changing it.

  `layer_status/2` reads a layer's last edit and its record count.
  `pages/2` reads every record of a layer as a lazy stream of pages of
  `Gobusgo.Addresses.FeaturePages.page_size/0` records, a request starting
  at most every #{@request_interval_ms} ms and at most #{@concurrency_max} in
  flight. A page whose request fails with a transient failure is asked for
  again, at most #{@attempt_count_max} times in all, after a delay that
  doubles from #{@retry_base_ms} ms to #{@retry_cap_ms} ms with jitter, or
  the delay a `Retry-After` header names.

  Every outcome the service documents is a value. Transport faults come back
  as `{:transport, reason}` and a status or body the service does not
  document as `{:unexpected_status, status}` or `{:malformed, path}`.

  Options: `:plug` (see `Gobusgo.Addresses.Http`), and for tests
  `:request_interval_ms` and `:retry_base_ms`.
  """

  alias Gobusgo.Addresses.FeaturePages
  alias Gobusgo.Addresses.Http
  alias Gobusgo.Assert
  alias Gobusgo.Schema

  @type layer_status :: %{last_edit_at: DateTime.t(), record_count: non_neg_integer()}

  @type error :: Http.error() | {:unexpected_status, pos_integer()} | FeaturePages.error()

  @typedoc """
  One item of `pages/2`: a page's features with the count of requests it
  took, or the failure that ends the stream, with the page's offset.
  """
  @type page ::
          {:features, [FeaturePages.feature()], pos_integer()}
          | {:failed, {:page, non_neg_integer(), error()} | :page_deadline_exceeded}

  @layer_schema {:map, %{"editingInfo" => {:map, %{"lastEditDate" => :integer}}}}
  @count_schema {:map, %{"count" => :integer}}

  @doc "The most requests one page takes, its retries included."
  @spec attempt_count_max() :: pos_integer()
  def attempt_count_max, do: @attempt_count_max

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
    # (`returnCountOnly`) — checked 2026-11-11
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
  A lazy stream of the pages of the `layer.record_count` records of the
  layer at `layer.layer_url`, each record holding the fields
  `layer.out_fields` and its point, in the order of the offsets. The stream
  ends after its last page, or after the first `{:failed, _}`; a consumer
  that stops early stops the requests in flight. A record count past
  `Gobusgo.Addresses.FeaturePages.record_count_max/0` is refused before any
  request.
  """
  @spec pages(
          %{layer_url: String.t(), out_fields: [String.t()], record_count: non_neg_integer()},
          keyword()
        ) :: {:ok, Enumerable.t(page())} | {:error, {:record_count_too_large, pos_integer()}}
  def pages(%{layer_url: layer_url, out_fields: out_fields, record_count: record_count}, options)
      when is_binary(layer_url) and is_list(out_fields) and is_list(options) do
    with {:ok, offsets} <- FeaturePages.offsets(record_count) do
      settings = %{
        layer_url: layer_url,
        out_fields: out_fields,
        request_interval_ms: Keyword.get(options, :request_interval_ms, @request_interval_ms),
        retry_base_ms: Keyword.get(options, :retry_base_ms, @retry_base_ms),
        options: options
      }

      stream =
        offsets
        |> paced(settings.request_interval_ms)
        |> Task.async_stream(&fetch_page(%{settings: settings, offset: &1, attempt_index: 0}),
          max_concurrency: @concurrency_max,
          ordered: true,
          timeout: page_deadline_ms(),
          on_timeout: :kill_task
        )
        |> Stream.transform(:reading, &page_item/2)

      {:ok, stream}
    end
  end

  # A page's task outlives every attempt's request deadline and every delay
  # between them, so only a request that hangs past its own deadline reaches
  # this one.
  defp page_deadline_ms do
    retry_count = @attempt_count_max - 1
    @attempt_count_max * Http.json_deadline_ms() + retry_count * @retry_cap_ms + @retry_cap_ms
  end

  # Each offset leaves no sooner than `interval_ms` after the one before it,
  # and the stream of tasks takes an offset only when it has a free slot, so
  # requests start at most once per interval.
  defp paced(offsets, interval_ms) do
    Stream.transform(offsets, nil, fn offset, previous_ms ->
      now_ms = System.monotonic_time(:millisecond)

      case previous_ms do
        nil -> :ok
        previous_ms -> Process.sleep(max(previous_ms + interval_ms - now_ms, 0))
      end

      {[offset], System.monotonic_time(:millisecond)}
    end)
  end

  defp page_item(_result, :failed), do: {:halt, :failed}

  defp page_item({:ok, {:features, _features, _count} = page}, :reading), do: {[page], :reading}

  defp page_item({:ok, {:failed, _reason} = failure}, :reading), do: {[failure], :failed}

  defp page_item({:exit, :timeout}, :reading), do: {[{:failed, :page_deadline_exceeded}], :failed}

  defp fetch_page(%{settings: settings, offset: offset, attempt_index: attempt_index} = request) do
    Assert.condition(
      attempt_index < @attempt_count_max,
      "attempt #{attempt_index} is past #{@attempt_count_max}"
    )

    url =
      FeaturePages.query_url(%{
        layer_url: settings.layer_url,
        out_fields: settings.out_fields,
        offset: offset
      })

    attempt_count = attempt_index + 1

    case request_page(url, settings) do
      {:ok, features} ->
        {:features, features, attempt_count}

      {:error, reason, retry_after_ms} ->
        is_retried = FeaturePages.transient?(reason) and attempt_count < @attempt_count_max

        if is_retried do
          Process.sleep(retry_delay_ms(settings, attempt_index, retry_after_ms))
          fetch_page(%{request | attempt_index: attempt_count})
        else
          {:failed, {:page, offset, reason}}
        end
    end
  end

  defp retry_delay_ms(settings, attempt_index, retry_after_ms) do
    FeaturePages.retry_delay_ms(%{
      attempt_index: attempt_index,
      base_ms: settings.retry_base_ms,
      cap_ms: @retry_cap_ms,
      retry_after_ms: retry_after_ms,
      jitter: :rand.uniform()
    })
  end

  defp request_page(url, settings) do
    case Http.get_json(%{url: url, bytes_max: @json_bytes_max}, settings.options) do
      {:ok, %{status: 200, body: body}} ->
        case FeaturePages.decode_page(body, settings.out_fields) do
          {:ok, features} -> {:ok, features}
          {:error, reason} -> {:error, reason, nil}
        end

      {:ok, %{status: status, retry_after: retry_after}} ->
        {:error, {:unexpected_status, status}, FeaturePages.retry_after_ms(retry_after)}

      {:error, reason} ->
        {:error, reason, nil}
    end
  end
end
