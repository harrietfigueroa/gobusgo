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
  @type routing :: %{dir: String.t()}
  @type routing_error :: {:missing, :dir}
  @type shared_vehicle_tiles :: %{dir: String.t()}
  @type shared_vehicle_tiles_error :: {:missing, :dir}

  @typedoc "The full commit the application was built from, or `nil` for a build that names none."
  @type revision :: String.t() | nil
  @type revision_error :: {:invalid, :revision}

  @typedoc "The address a page links for donations, or `nil` for an application that links none."
  @type donation_url :: String.t() | nil
  @type donation_url_error :: {:invalid, :donation_url}

  @type one_bus_away :: Gobusgo.Config.OneBusAway.t()
  @type one_bus_away_error :: {:missing, :base_url | :api_key}

  @type ingestion :: %{scheduled: boolean()}
  @type ingestion_error :: {:invalid, :scheduled}

  @type usage :: %{recorded: boolean()}
  @type usage_error :: {:invalid, :recorded}

  @type shared_vehicles :: %{interval_ms: pos_integer()}
  @type shared_vehicles_error :: {:invalid, :shared_vehicles_interval_ms}

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
  # A shared vehicle feed declares a `ttl` of 60 seconds, so a shorter
  # interval fetches the same file again.
  @shared_vehicles_interval_ms_default 60_000
  @shared_vehicles_interval_ms_min 60_000
  @shared_vehicles_interval_ms_max 3_600_000
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

  # A full Git commit name is the 40 lowercase hexadecimal digits of a SHA-1
  # hash, the object format of the repository.
  @revision_pattern ~r/\A[0-9a-f]{40}\z/

  # The address a relative credentials URI is appended to.
  # https://docs.aws.amazon.com/sdkref/latest/guide/feature-container-credentials.html — checked 2026-10-11
  @credentials_host "http://169.254.170.2"

  @doc """
  Returns the OneBusAway settings from `env`, or the first missing key.
  A nil or blank value counts as missing.
  """
  @spec fetch_one_bus_away(Keyword.t()) :: {:ok, one_bus_away()} | {:error, one_bus_away_error()}
  def fetch_one_bus_away(env) when is_list(env) do
    found =
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

    case found do
      {:ok, settings} -> {:ok, struct!(Gobusgo.Config.OneBusAway, settings)}
      {:error, _missing} = error -> error
    end
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
  Returns the shared vehicle settings from `env`: `:interval_ms`, how often
  the shared vehicle feeds are fetched while a page shows them, an integer
  of milliseconds from #{@shared_vehicles_interval_ms_min} to
  #{@shared_vehicles_interval_ms_max}. A missing value takes the default,
  #{@shared_vehicles_interval_ms_default}.
  """
  @spec fetch_shared_vehicles(Keyword.t()) ::
          {:ok, shared_vehicles()} | {:error, shared_vehicles_error()}
  def fetch_shared_vehicles(env) when is_list(env) do
    case Keyword.fetch(env, :interval_ms) do
      :error ->
        {:ok, %{interval_ms: @shared_vehicles_interval_ms_default}}

      {:ok, interval_ms}
      when is_integer(interval_ms) and interval_ms >= @shared_vehicles_interval_ms_min and
             interval_ms <= @shared_vehicles_interval_ms_max ->
        {:ok, %{interval_ms: interval_ms}}

      {:ok, _other} ->
        {:error, {:invalid, :shared_vehicles_interval_ms}}
    end
  end

  @doc "Reads the shared vehicle settings configured for the running application."
  @spec shared_vehicles() :: {:ok, shared_vehicles()} | {:error, shared_vehicles_error()}
  def shared_vehicles do
    :gobusgo |> Application.get_env(:shared_vehicles, []) |> fetch_shared_vehicles()
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

  @doc """
  Returns the routing settings from `env`: `:dir`, the directory the locally
  stored routing snapshot files are served from. A nil or blank value counts
  as missing.
  """
  @spec fetch_routing(Keyword.t()) :: {:ok, routing()} | {:error, routing_error()}
  def fetch_routing(env) when is_list(env), do: fetch_dir(env)

  @doc """
  Returns the shared vehicle tile settings from `env`: `:dir`, the directory
  the locally stored shared vehicle files are served from. A nil or blank
  value counts as missing.
  """
  @spec fetch_shared_vehicle_tiles(Keyword.t()) ::
          {:ok, shared_vehicle_tiles()} | {:error, shared_vehicle_tiles_error()}
  def fetch_shared_vehicle_tiles(env) when is_list(env), do: fetch_dir(env)

  @doc """
  Returns the commit the application was built from, from `env`:
  `:revision`, a full commit name of 40 lowercase hexadecimal digits. A nil
  or blank value is `{:ok, nil}`, a build that names no commit.
  """
  @spec fetch_revision(Keyword.t()) :: {:ok, revision()} | {:error, revision_error()}
  def fetch_revision(env) when is_list(env) do
    case text(env, :revision) do
      nil ->
        {:ok, nil}

      revision ->
        if Regex.match?(@revision_pattern, revision) do
          {:ok, revision}
        else
          {:error, {:invalid, :revision}}
        end
    end
  end

  @doc """
  Returns the address a page links for donations, from `env`: `:url`, an
  `https` address with a host. A nil or blank value is `{:ok, nil}`, an
  application that links no donation page.
  """
  @spec fetch_donation_url(Keyword.t()) :: {:ok, donation_url()} | {:error, donation_url_error()}
  def fetch_donation_url(env) when is_list(env) do
    case text(env, :url) do
      nil ->
        {:ok, nil}

      url ->
        if donation_url?(url), do: {:ok, url}, else: {:error, {:invalid, :donation_url}}
    end
  end

  @doc "Reads the donation address configured for the running application."
  @spec donation_url() :: {:ok, donation_url()} | {:error, donation_url_error()}
  def donation_url do
    :gobusgo |> Application.get_env(:donation, []) |> fetch_donation_url()
  end

  @doc "Reads the commit the running application was built from."
  @spec revision() :: {:ok, revision()} | {:error, revision_error()}
  def revision do
    :gobusgo |> Application.get_env(:revision, []) |> fetch_revision()
  end

  @doc "Reads the routing settings configured for the running application."
  @spec routing() :: {:ok, routing()} | {:error, routing_error()}
  def routing do
    :gobusgo |> Application.get_env(:routing, []) |> fetch_routing()
  end

  @doc "Reads the shared vehicle tile settings configured for the running application."
  @spec shared_vehicle_tiles() ::
          {:ok, shared_vehicle_tiles()} | {:error, shared_vehicle_tiles_error()}
  def shared_vehicle_tiles do
    :gobusgo |> Application.get_env(:shared_vehicle_tiles, []) |> fetch_shared_vehicle_tiles()
  end

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

  # `URI.new/1` refuses an address with a space or another character an
  # address cannot hold.
  defp donation_url?(url) do
    case URI.new(url) do
      {:ok, %URI{scheme: "https", host: host}} when is_binary(host) and host != "" -> true
      {:ok, %URI{}} -> false
      {:error, _part} -> false
    end
  end

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
