defmodule Gobusgo.Config do
  @moduledoc """
  Validated access to runtime settings. Everything here is pure: callers pass
  the application environment in, which keeps validation testable without
  global state.
  """

  @type basemap :: %{dir: String.t()}
  @type basemap_error :: {:missing, :dir}
  @type tiles :: %{dir: String.t()}
  @type tiles_error :: {:missing, :dir}

  @type one_bus_away :: %{base_url: String.t(), api_key: String.t()}
  @type one_bus_away_error :: {:missing, :base_url | :api_key}

  @type ingestion :: %{scheduled: boolean()}
  @type ingestion_error :: {:invalid, :scheduled}

  @type usage :: %{recorded: boolean()}
  @type usage_error :: {:invalid, :recorded}

  @type http :: %{ip: :inet.ip_address(), port: :inet.port_number()}
  @type http_error :: {:invalid, :host | :port}

  @typedoc """
  Where the writer, the reader, and the deleter keep content: `:local`, or
  the bucket with the key prefix, the region, the address the bucket is
  reached at, and the source of the credentials.
  """
  @type storage ::
          :local
          | %{
              bucket: String.t(),
              prefix: String.t(),
              region: String.t(),
              endpoint: String.t(),
              credentials: Gobusgo.S3.Credentials.source()
            }
  @type storage_error ::
          {:invalid, :bucket | :prefix | :region | :endpoint | :credentials_uri}
          | {:missing, :region | :credentials_uri}

  @one_bus_away_keys [:base_url, :api_key]
  @http_host_default "127.0.0.1"
  @http_port_default 4000
  @http_port_min 1
  @http_port_max 65_535
  @secret_key_base_bytes_min 64
  # A host name is at most 253 bytes of labels, each at most 63.
  # https://www.rfc-editor.org/rfc/rfc1035#section-2.3.4 — checked 2026-10-09
  @public_host_bytes_max 253
  @public_host_label ~S"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"

  # A bucket name is 3 to 63 characters of lowercase letters, digits, dots,
  # and hyphens, and begins and ends with a letter or a digit.
  # https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html — checked 2026-10-11
  @bucket_pattern ~r/\A[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]\z/
  @region_pattern ~r/\A[a-z0-9]+(?:-[a-z0-9]+)+\z/
  @endpoint_pattern ~r/\Ahttps:\/\/[a-z0-9.-]+(?::[0-9]{1,5})?\z/

  # The address a relative credentials URI is appended to.
  # https://docs.aws.amazon.com/sdkref/latest/guide/feature-container-credentials.html — checked 2026-10-11
  @credentials_host "http://169.254.170.2"

  @doc """
  Returns the OneBusAway settings from `env`, or the first missing key.
  A nil or blank value counts as missing.
  """
  @spec fetch_one_bus_away(Keyword.t()) :: {:ok, one_bus_away()} | {:error, one_bus_away_error()}
  def fetch_one_bus_away(env) when is_list(env) do
    Enum.reduce_while(@one_bus_away_keys, {:ok, %{}}, fn key, {:ok, settings} ->
      case Keyword.get(env, key) do
        value when is_binary(value) ->
          if String.trim(value) == "" do
            {:halt, {:error, {:missing, key}}}
          else
            {:cont, {:ok, Map.put(settings, key, value)}}
          end

        nil ->
          {:halt, {:error, {:missing, key}}}
      end
    end)
  end

  @doc "Reads the OneBusAway settings configured for the running application."
  @spec one_bus_away() :: {:ok, one_bus_away()} | {:error, one_bus_away_error()}
  def one_bus_away do
    :gobusgo |> Application.get_env(:one_bus_away, []) |> fetch_one_bus_away()
  end

  @doc """
  Returns the ingestion settings from `env`: `:scheduled`, whether the
  sources run on their schedule. Returns the first value that is not valid;
  a missing value is not valid.
  """
  @spec fetch_ingestion(Keyword.t()) :: {:ok, ingestion()} | {:error, ingestion_error()}
  def fetch_ingestion(env) when is_list(env) do
    case Keyword.get(env, :scheduled) do
      scheduled when is_boolean(scheduled) -> {:ok, %{scheduled: scheduled}}
      _other -> {:error, {:invalid, :scheduled}}
    end
  end

  @doc "Reads the ingestion settings configured for the running application."
  @spec ingestion() :: {:ok, ingestion()} | {:error, ingestion_error()}
  def ingestion do
    :gobusgo |> Application.get_env(:ingestion, []) |> fetch_ingestion()
  end

  @doc """
  Returns the usage settings from `env`: `:recorded`, whether page
  connections are recorded. Returns the first value that is not valid; a
  missing value is not valid.
  """
  @spec fetch_usage(Keyword.t()) :: {:ok, usage()} | {:error, usage_error()}
  def fetch_usage(env) when is_list(env) do
    case Keyword.get(env, :recorded) do
      recorded when is_boolean(recorded) -> {:ok, %{recorded: recorded}}
      _other -> {:error, {:invalid, :recorded}}
    end
  end

  @doc "Reads the usage settings configured for the running application."
  @spec usage() :: {:ok, usage()} | {:error, usage_error()}
  def usage do
    :gobusgo |> Application.get_env(:usage, []) |> fetch_usage()
  end

  @doc """
  Returns the HTTP listener settings from `env`: `:host`, an IPv4 or IPv6
  address as text, and `:port`, a decimal port number as text. A nil or
  blank value takes the default, `#{@http_host_default}` and
  `#{@http_port_default}`. Returns the first value that is not valid.
  """
  @spec fetch_http(Keyword.t()) :: {:ok, http()} | {:error, http_error()}
  def fetch_http(env) when is_list(env) do
    with {:ok, ip} <- parse_ip(text(env, :host) || @http_host_default),
         {:ok, port} <- parse_port(text(env, :port)) do
      {:ok, %{ip: ip, port: port}}
    end
  end

  @doc "Reads the HTTP listener settings configured for the running application."
  @spec http() :: {:ok, http()} | {:error, http_error()}
  def http do
    :gobusgo |> Application.get_env(:http, []) |> fetch_http()
  end

  @doc """
  Returns the basemap settings from `env`: `:dir`, the directory the basemap
  archives are served from. A nil or blank value counts as missing.
  """
  @spec fetch_basemap(Keyword.t()) :: {:ok, basemap()} | {:error, basemap_error()}
  def fetch_basemap(env) when is_list(env), do: fetch_dir(env)

  @doc "Reads the basemap settings configured for the running application."
  @spec basemap() :: {:ok, basemap()} | {:error, basemap_error()}
  def basemap do
    :gobusgo |> Application.get_env(:basemap, []) |> fetch_basemap()
  end

  @doc """
  Returns the tile settings from `env`: `:dir`, the directory the locally
  stored tile archives are served from. A nil or blank value counts as
  missing.
  """
  @spec fetch_tiles(Keyword.t()) :: {:ok, tiles()} | {:error, tiles_error()}
  def fetch_tiles(env) when is_list(env), do: fetch_dir(env)

  @doc "Reads the tile settings configured for the running application."
  @spec tiles() :: {:ok, tiles()} | {:error, tiles_error()}
  def tiles do
    :gobusgo |> Application.get_env(:tiles, []) |> fetch_tiles()
  end

  defp fetch_dir(env) do
    case Keyword.get(env, :dir) do
      dir when is_binary(dir) ->
        if String.trim(dir) == "" do
          {:error, {:missing, :dir}}
        else
          {:ok, %{dir: dir}}
        end

      nil ->
        {:error, {:missing, :dir}}
    end
  end

  @doc """
  Returns the secret that signs sessions from `env`: `:secret_key_base`,
  text of at least #{@secret_key_base_bytes_min} bytes, and `:required`, a
  boolean. A nil or blank secret is `{:ok, nil}` when it is not required and
  `{:error, {:missing, :secret_key_base}}` when it is.
  """
  @spec fetch_secret_key_base(Keyword.t()) ::
          {:ok, String.t() | nil} | {:error, {:missing | :invalid, :secret_key_base}}
  def fetch_secret_key_base(env) when is_list(env) do
    required = Keyword.fetch!(env, :required)

    case text(env, :secret_key_base) do
      nil ->
        if required, do: {:error, {:missing, :secret_key_base}}, else: {:ok, nil}

      secret ->
        if byte_size(secret) >= @secret_key_base_bytes_min do
          {:ok, secret}
        else
          {:error, {:invalid, :secret_key_base}}
        end
    end
  end

  @doc "Reads the session secret configured for the running application."
  @spec secret_key_base() ::
          {:ok, String.t() | nil} | {:error, {:missing | :invalid, :secret_key_base}}
  def secret_key_base do
    :gobusgo |> Application.fetch_env!(:session) |> fetch_secret_key_base()
  end

  @doc """
  Returns the public host name from `env`: `:host`, the name pages are
  served on, in lowercase with no scheme, port, or path, and `:required`, a
  boolean. A nil or blank host name is `{:ok, nil}` when it is not required
  and `{:error, {:missing, :public_host}}` when it is.
  """
  @spec fetch_public_host(Keyword.t()) ::
          {:ok, String.t() | nil} | {:error, {:missing | :invalid, :public_host}}
  def fetch_public_host(env) when is_list(env) do
    required = Keyword.fetch!(env, :required)

    case text(env, :host) do
      nil ->
        if required, do: {:error, {:missing, :public_host}}, else: {:ok, nil}

      host ->
        if public_host?(host), do: {:ok, host}, else: {:error, {:invalid, :public_host}}
    end
  end

  @doc "Reads the public host name configured for the running application."
  @spec public_host() ::
          {:ok, String.t() | nil} | {:error, {:missing | :invalid, :public_host}}
  def public_host do
    :gobusgo |> Application.fetch_env!(:public) |> fetch_public_host()
  end

  @doc """
  Returns where content is stored from `env`. A nil or blank `:bucket` is
  `{:ok, :local}`. With a bucket, `:region` is required, `:prefix` is empty
  or destination segments that end in `/`, and `:endpoint`, an `https`
  address with no path, defaults to the bucket's regional address. The
  credentials come from `:credentials_relative_uri`, a path at the container
  credentials address, or else from `:credentials_full_uri`, with
  `:credentials_authorization` as the header either asks for; one of the two
  is required. Returns the first value that is missing or not valid.
  """
  @spec fetch_storage(Keyword.t()) :: {:ok, storage()} | {:error, storage_error()}
  def fetch_storage(env) when is_list(env) do
    case text(env, :bucket) do
      nil ->
        {:ok, :local}

      bucket ->
        with :ok <- check(Regex.match?(@bucket_pattern, bucket), {:invalid, :bucket}),
             {:ok, region} <- storage_region(env),
             {:ok, prefix} <- storage_prefix(env),
             {:ok, endpoint} <- storage_endpoint(env, %{bucket: bucket, region: region}),
             {:ok, credentials_url} <- storage_credentials_url(env) do
          {:ok,
           %{
             bucket: bucket,
             prefix: prefix,
             region: region,
             endpoint: endpoint,
             credentials: %{
               url: credentials_url,
               authorization: text(env, :credentials_authorization)
             }
           }}
        end
    end
  end

  @doc "Reads where content is stored, as configured for the running application."
  @spec storage() :: {:ok, storage()} | {:error, storage_error()}
  def storage do
    :gobusgo |> Application.get_env(Gobusgo.S3, []) |> fetch_storage()
  end

  defp storage_region(env) do
    case text(env, :region) do
      nil ->
        {:error, {:missing, :region}}

      region ->
        if Regex.match?(@region_pattern, region),
          do: {:ok, region},
          else: {:error, {:invalid, :region}}
    end
  end

  defp storage_prefix(env) do
    prefix = text(env, :prefix) || ""
    if Gobusgo.S3.Key.prefix?(prefix), do: {:ok, prefix}, else: {:error, {:invalid, :prefix}}
  end

  defp storage_endpoint(env, location) do
    case text(env, :endpoint) do
      nil ->
        {:ok, Gobusgo.S3.Client.endpoint(location)}

      endpoint ->
        if Regex.match?(@endpoint_pattern, endpoint),
          do: {:ok, endpoint},
          else: {:error, {:invalid, :endpoint}}
    end
  end

  defp storage_credentials_url(env) do
    case {text(env, :credentials_relative_uri), text(env, :credentials_full_uri)} do
      {nil, nil} ->
        {:error, {:missing, :credentials_uri}}

      {nil, "http://" <> _rest = full_uri} ->
        {:ok, full_uri}

      {nil, "https://" <> _rest = full_uri} ->
        {:ok, full_uri}

      {"/" <> _rest = relative_uri, _full_uri} ->
        {:ok, @credentials_host <> relative_uri}

      _other ->
        {:error, {:invalid, :credentials_uri}}
    end
  end

  defp check(true, _error), do: :ok
  defp check(false, error), do: {:error, error}

  defp public_host?(host) do
    byte_size(host) <= @public_host_bytes_max and
      Regex.match?(~r/\A#{@public_host_label}(?:\.#{@public_host_label})*\z/, host)
  end

  defp text(env, key) do
    case Keyword.get(env, key) do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> nil
          _trimmed -> value
        end

      nil ->
        nil
    end
  end

  defp parse_ip(host) do
    case :inet.parse_strict_address(String.to_charlist(host)) do
      {:ok, ip} -> {:ok, ip}
      {:error, :einval} -> {:error, {:invalid, :host}}
    end
  end

  defp parse_port(nil), do: {:ok, @http_port_default}

  defp parse_port(text) do
    case Integer.parse(text) do
      {port, ""} when port >= @http_port_min and port <= @http_port_max -> {:ok, port}
      _other -> {:error, {:invalid, :port}}
    end
  end
end
