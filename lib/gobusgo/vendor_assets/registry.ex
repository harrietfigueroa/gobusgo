defmodule Gobusgo.VendorAssets.Registry do
  @attempt_count_max 3
  @deadline_ms 120_000
  @metadata_bytes_max 1_048_576
  @tarball_bytes_max 67_108_864

  @moduledoc """
  The npm registry requests of the vendored packages: the metadata of one
  version of a package, and a tarball. Read `AGENTS.md` beside this module
  before changing it.

  A request makes at most #{@attempt_count_max} attempts and ends within
  #{@deadline_ms} milliseconds. Metadata of more than #{@metadata_bytes_max}
  bytes and a tarball of more than #{@tarball_bytes_max} bytes are refused.

  Errors, shared by both functions:

    * `:not_found`: the registry has no such package, version, or tarball
    * `{:http_status, status}`: any other status that is not 200
    * `{:transport, reason}`: a network fault such as `:timeout`
    * `:deadline_exceeded`: all attempts together outlasted the deadline
    * `:body_too_large`: the response exceeds its bound

  `fetch_version/2` also returns `:invalid_json`, `:invalid_metadata` for
  metadata without a version, a tarball address, or an integrity that a lock
  accepts.

  Options: `:plug`, a plug that answers the requests in place of the
  network, and `:retry_delay_ms_base`, the first retry's delay window.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Schema
  alias Gobusgo.VendorAssets.Lock

  @base_url "https://registry.npmjs.org"
  @latest "latest"
  @connect_timeout_ms 10_000
  @receive_timeout_ms 30_000
  @retry_delay_ms_base 500
  @retry_delay_ms_cap 8_000
  @retry_after_ms_max 30_000
  @retry_statuses [408, 429, 500, 502, 503, 504]

  @version_schema {:map,
                   %{
                     "name" => :string,
                     "version" => :string,
                     "dist" => {:map, %{"tarball" => :string, "integrity" => :string}}
                   }}

  @type version :: %{version: String.t(), tarball: String.t(), integrity: String.t()}
  @type error ::
          :not_found
          | {:http_status, pos_integer()}
          | {:transport, term()}
          | :deadline_exceeded
          | :body_too_large

  @doc """
  Returns the version, the tarball address, and the tarball integrity of
  `request.version` of the package `request.name`. The version is a version
  number or `:latest`, the version the registry's `latest` tag names.
  """
  @spec fetch_version(%{name: String.t(), version: String.t() | :latest}, keyword()) ::
          {:ok, version()} | {:error, error() | :invalid_json | :invalid_metadata}
  def fetch_version(%{name: name, version: version}, options) when is_list(options) do
    Assert.condition(Lock.valid_name?(name), "name must be a package name, got: #{inspect(name)}")

    version_segment =
      case version do
        :latest ->
          @latest

        version ->
          Assert.condition(Lock.valid_version?(version), "version must be a version number")
          version
      end

    # GET /{package}/{version}, where the version is a number or `latest`:
    # https://github.com/npm/registry/blob/main/docs/REGISTRY-API.md — checked 2026-10-04
    with {:ok, body} <-
           get("#{@base_url}/#{name}/#{version_segment}", @metadata_bytes_max, options) do
      parse_version(body, name)
    end
  end

  @doc "Returns the tarball at `url`, an address a lock accepts."
  @spec fetch_tarball(String.t(), keyword()) :: {:ok, binary()} | {:error, error()}
  def fetch_tarball(url, options) when is_binary(url) and is_list(options) do
    Assert.condition(
      String.starts_with?(url, @base_url <> "/"),
      "tarball must be on #{@base_url}"
    )

    get(url, @tarball_bytes_max, options)
  end

  defp parse_version(body, name) do
    with {:ok, decoded} <- decode_json(body),
         nil <- Schema.mismatch(decoded, @version_schema),
         %{"name" => ^name, "version" => version, "dist" => dist} <- decoded,
         %{"tarball" => tarball, "integrity" => integrity} = dist,
         true <- Lock.valid_version?(version),
         true <- Lock.valid_tarball?(tarball),
         true <- Lock.valid_integrity?(integrity) do
      {:ok, %{version: version, tarball: tarball, integrity: integrity}}
    else
      {:error, :invalid_json} -> {:error, :invalid_json}
      _other -> {:error, :invalid_metadata}
    end
  end

  defp decode_json(body) do
    case JSON.decode(body) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  # The request runs in a task so that the deadline bounds every attempt and
  # every wait between attempts together.
  defp get(url, bytes_max, options) do
    task = Task.async(fn -> request(url, bytes_max, options) end)

    case Task.yield(task, @deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} ->
        outcome

      nil ->
        {:error, :deadline_exceeded}

      {:exit, reason} ->
        raise Assert.AssertionError, message: "request task exited: #{inspect(reason)}"
    end
  end

  defp request(url, bytes_max, options) do
    delay_ms_base = Keyword.get(options, :retry_delay_ms_base, @retry_delay_ms_base)

    request_options =
      [
        url: url,
        headers: [accept: "application/json, application/octet-stream"],
        decode_body: false,
        compressed: false,
        redirect: false,
        retry: &retry(&1, &2, delay_ms_base),
        max_retries: @attempt_count_max - 1,
        retry_log_level: false,
        receive_timeout: @receive_timeout_ms,
        connect_options: [timeout: @connect_timeout_ms],
        into: &collect(&1, &2, bytes_max)
      ] ++ plug_option(Keyword.get(options, :plug))

    case Req.get(request_options) do
      {:ok, %Req.Response{private: %{body_too_large: true}}} ->
        {:error, :body_too_large}

      {:ok, %Req.Response{status: 200, body: body}} ->
        {:ok, body}

      # The registry answers 404 for a package, a version, or a tarball it
      # does not have. The API page documents no error status; observed on
      # 2026-10-04 for `GET /maplibre-gl/99.0.0`.
      # https://github.com/npm/registry/blob/main/docs/REGISTRY-API.md — checked 2026-10-04
      {:ok, %Req.Response{status: 404}} ->
        {:error, :not_found}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_status, status}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport, reason}}

      {:error, exception} ->
        raise Assert.AssertionError,
          message: "unrecognized request failure #{inspect(exception.__struct__)}"
    end
  end

  # Stops reading a body once it passes its bound, so a response cannot fill
  # memory.
  defp collect({:data, data}, {request, response}, bytes_max) do
    body = response.body <> data

    if byte_size(body) <= bytes_max do
      {:cont, {request, %{response | body: body}}}
    else
      {:halt, {request, Req.Response.put_private(%{response | body: ""}, :body_too_large, true)}}
    end
  end

  # Full jitter over an exponential window, so synchronized callers spread
  # out; a Retry-After the response carries takes the window's place.
  defp retry(request, %Req.Response{status: status} = response, delay_ms_base) do
    if status in @retry_statuses do
      case retry_after_ms(response) do
        nil -> {:delay, jittered_delay_ms(request, delay_ms_base)}
        retry_after_ms -> {:delay, min(retry_after_ms, @retry_after_ms_max)}
      end
    else
      false
    end
  end

  defp retry(request, %Req.TransportError{}, delay_ms_base) do
    {:delay, jittered_delay_ms(request, delay_ms_base)}
  end

  defp retry(_request, %{__exception__: true}, _delay_ms_base), do: false

  # A Retry-After value that is malformed or in the past names no time.
  defp retry_after_ms(response) do
    case Req.Response.get_retry_after(response) do
      retry_after_ms when is_integer(retry_after_ms) -> max(retry_after_ms, 0)
      nil -> nil
    end
  rescue
    _exception -> nil
  end

  defp jittered_delay_ms(request, delay_ms_base) do
    retry_count = Req.Request.get_private(request, :req_retry_count, 0)
    window_ms = min(@retry_delay_ms_cap, delay_ms_base * Integer.pow(2, retry_count))
    :rand.uniform(max(window_ms, 1))
  end

  defp plug_option(nil), do: []
  defp plug_option(plug), do: [plug: plug]
end
