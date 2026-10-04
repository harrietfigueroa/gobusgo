defmodule Gobusgo.VendorAssets.Registry do
  @metadata_bytes_max 1_048_576
  @tarball_bytes_max 67_108_864

  @moduledoc """
  The npm registry requests of the vendored packages: the metadata of one
  version of a package, and a tarball. Read `AGENTS.md` beside this module
  before changing it.

  Requests go through `Gobusgo.VendorAssets.Http`, which bounds their
  attempts and their time. Metadata of more than #{@metadata_bytes_max}
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

  Options are those of `Gobusgo.VendorAssets.Http.get/2`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Schema
  alias Gobusgo.VendorAssets.Http
  alias Gobusgo.VendorAssets.Lock

  @base_url "https://registry.npmjs.org"
  @latest "latest"
  @accept "application/json, application/octet-stream"

  @version_schema {:map,
                   %{
                     "name" => :string,
                     "version" => :string,
                     "dist" => {:map, %{"tarball" => :string, "integrity" => :string}}
                   }}

  @type version :: %{version: String.t(), tarball: String.t(), integrity: String.t()}
  @type error :: :not_found | {:http_status, pos_integer()} | Http.error()

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

  defp get(url, bytes_max, options) do
    request = %{url: url, headers: [{"accept", @accept}], bytes_max: bytes_max}

    case Http.get(request, options) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      # The registry answers 404 for a package, a version, or a tarball it
      # does not have. The API page documents no error status; observed on
      # 2026-10-04 for `GET /maplibre-gl/99.0.0`.
      # https://github.com/npm/registry/blob/main/docs/REGISTRY-API.md — checked 2026-10-04
      {:ok, %{status: 404}} ->
        {:error, :not_found}

      {:ok, %{status: status}} ->
        {:error, {:http_status, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
