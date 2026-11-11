defmodule Gobusgo.Addresses.FeaturePages do
  @page_size 100
  @attempt_count_max 3
  @retry_base_ms 500
  @retry_delay_ms_max 30_000
  @features_bytes_max 4_194_304

  @moduledoc """
  The pages of an ArcGIS FeatureServer layer, as a lazy stream. Read
  `lib/gobusgo/addresses/AGENTS.md` before changing it.

  `stream/2` queries the layer's `query` endpoint for #{@page_size} features
  at a time, in the order of their `OBJECTID`, each query asking for the
  features above the last `OBJECTID` the page before it held, with the
  coordinates in WGS 84 (`outSR=4326`), so the layer needs no projection
  here and no page reads a deep offset
  (<https://developers.arcgis.com/rest/services-reference/enterprise/query-feature-service-layer/>
  — checked 2026-11-10). The #{@page_size} is the style guide's ceiling for
  one request; the services allow 2,000.

  The stream emits one element per page, `{:page, features}` for a page that
  holds features, or `{:error, reason}` once and then ends. No request is
  made until the stream is read, one request at a time, and a stream is
  never read past `request.page_count_max` pages: a layer that needs more
  ends with `{:error, :page_count_exceeded}`.

  A request is retried up to #{@attempt_count_max} attempts in all, only for
  a failure the service marks transient: a network fault, a deadline, a
  status of 408, 429, or 5xx, or an error object whose `code` is one of
  those, which ArcGIS answers with a `200`. The delay before a retry doubles
  from `:retry_base_ms` (default #{@retry_base_ms}) with jitter, and a
  `Retry-After` header in seconds replaces it, at most
  #{@retry_delay_ms_max} ms. Every other failure is a value:

    * `{:unexpected_status, status}`: a status the service does not document
    * `{:service_error, code}`: an error object with a code that is not transient
    * `{:malformed, path}`: a body of another shape, a page with no `OBJECTID`
    * `:no_progress`: a full page whose `OBJECTID`s do not rise past the last
    * `{:transport, reason}`, `:deadline_exceeded`, `:body_too_large`: as
      `Gobusgo.Addresses.Http` reports them, after the attempts

  Options: `:plug`, as `Gobusgo.Addresses.Http`; `:retry_base_ms`.
  """

  alias Gobusgo.Addresses.Http
  alias Gobusgo.Schema

  @type request :: %{
          url: String.t(),
          out_fields: [String.t(), ...],
          page_count_max: pos_integer()
        }

  @type feature :: %{String.t() => term()}

  @type error ::
          Http.error()
          | {:unexpected_status, pos_integer()}
          | {:service_error, integer()}
          | {:malformed, String.t()}
          | :no_progress
          | :page_count_exceeded

  @page_schema {:map,
                %{
                  "features" =>
                    {:list,
                     {:map,
                      %{
                        "attributes" => {:map, %{"OBJECTID" => :integer}},
                        "geometry" => {:optional, {:nullable, {:map, %{}}}}
                      }}},
                  "exceededTransferLimit" => {:optional, :boolean}
                }}
  @error_schema {:map, %{"error" => {:map, %{"code" => :integer}}}}

  @doc "The count of features one request asks for."
  @spec page_size() :: pos_integer()
  def page_size, do: @page_size

  @doc """
  The lazy stream of the pages of the layer whose `query` address is
  `request.url`, with the attribute fields `request.out_fields`, which name
  `OBJECTID`.
  """
  @spec stream(request(), keyword()) :: Enumerable.t({:page, [feature()]} | {:error, error()})
  def stream(
        %{url: url, out_fields: out_fields, page_count_max: page_count_max} = request,
        options
      )
      when is_binary(url) and is_list(out_fields) and is_integer(page_count_max) and
             page_count_max > 0 and is_list(options) do
    true = "OBJECTID" in out_fields

    Stream.resource(
      fn -> %{last: 0, pages_left: page_count_max, done: false} end,
      fn
        %{done: true} = state -> {:halt, state}
        state -> next_page(request, state, options)
      end,
      fn _state -> :ok end
    )
  end

  defp next_page(_request, %{pages_left: 0} = state, _options) do
    {[{:error, :page_count_exceeded}], %{state | done: true}}
  end

  defp next_page(request, state, options) do
    case fetch(request, state.last, options) do
      {:ok, []} ->
        {[], %{state | done: true}}

      {:ok, features} ->
        advance(features, state)

      {:error, _reason} = failure ->
        {[failure], %{state | done: true}}
    end
  end

  defp advance(features, state) do
    last = features |> Enum.map(& &1["attributes"]["OBJECTID"]) |> Enum.max()

    cond do
      last <= state.last ->
        {[{:error, :no_progress}], %{state | done: true}}

      length(features) < @page_size ->
        {[{:page, features}], %{state | last: last, done: true}}

      true ->
        {[{:page, features}], %{state | last: last, pages_left: state.pages_left - 1}}
    end
  end

  defp fetch(request, last, options) do
    query =
      URI.encode_query(%{
        "where" => "OBJECTID>#{last}",
        "outFields" => Enum.join(request.out_fields, ","),
        "outSR" => "4326",
        "orderByFields" => "OBJECTID",
        "resultRecordCount" => Integer.to_string(@page_size),
        "returnGeometry" => "true",
        "f" => "json"
      })

    attempt(%{
      url: request.url <> "?" <> query,
      attempts_left: @attempt_count_max,
      delay_ms: Keyword.get(options, :retry_base_ms, @retry_base_ms),
      options: options
    })
  end

  defp attempt(%{url: url, options: options} = state) do
    outcome =
      case Http.get_json(%{url: url, bytes_max: @features_bytes_max}, options) do
        {:ok, %{status: 200, body: body}} -> decode(body)
        {:ok, %{status: status} = response} -> {:status, status, response.retry_after}
        {:error, _reason} = failure -> failure
      end

    case outcome do
      {:ok, features} ->
        {:ok, features}

      other ->
        retry_or_fail(other, state)
    end
  end

  defp retry_or_fail(outcome, %{attempts_left: attempts_left} = state) do
    {reason, retry_after} = classify(outcome)

    if transient?(reason) and attempts_left > 1 do
      Process.sleep(delay_ms(state.delay_ms, retry_after))
      attempt(%{state | attempts_left: attempts_left - 1, delay_ms: state.delay_ms * 2})
    else
      {:error, reason}
    end
  end

  defp classify({:status, status, retry_after}), do: {{:unexpected_status, status}, retry_after}
  defp classify({:error, reason}), do: {reason, nil}

  defp transient?({:transport, _reason}), do: true
  defp transient?(:deadline_exceeded), do: true
  defp transient?({:unexpected_status, status}), do: transient_code?(status)
  defp transient?({:service_error, code}), do: transient_code?(code)
  defp transient?(_reason), do: false

  defp transient_code?(code), do: code == 408 or code == 429 or (code >= 500 and code <= 599)

  # The computed delay is jittered between half and all of itself.
  defp delay_ms(computed_ms, nil) do
    half_ms = Integer.floor_div(computed_ms, 2)
    half_ms + :rand.uniform(max(computed_ms - half_ms, 1)) - 1
  end

  defp delay_ms(computed_ms, retry_after) do
    case Integer.parse(retry_after) do
      {seconds, ""} when seconds >= 0 -> min(seconds * 1_000, @retry_delay_ms_max)
      _unparsed -> delay_ms(computed_ms, nil)
    end
  end

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> check(decoded)
      {:error, _reason} -> {:error, {:malformed, "root"}}
    end
  end

  defp check(decoded) do
    case Schema.mismatch(decoded, @error_schema) do
      nil -> {:error, {:service_error, decoded["error"]["code"]}}
      _no_error -> check_page(decoded)
    end
  end

  defp check_page(decoded) do
    case Schema.mismatch(decoded, @page_schema) do
      nil -> {:ok, decoded["features"]}
      %{path: path} -> {:error, {:malformed, Schema.format_path(path)}}
    end
  end
end
