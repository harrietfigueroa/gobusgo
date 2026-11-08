defmodule Gobusgo.Gbfs.Client do
  @body_bytes_max 8 * 1024 * 1024
  @files [:vehicle_status, :vehicle_types]

  @moduledoc """
  The one place that talks HTTP to a GBFS feed. A system is read through the
  discovery file of each version it names, newest first, and a fetch
  returns the first version that publishes the file asked for. Read
  `lib/gobusgo/gbfs/AGENTS.md` before changing it.

  `fetch/3` reads one of #{inspect(@files)}. It returns the file's records
  as values, a version passed over as a value, and every failure as a value
  that names its cause; it raises only for arguments that break its
  contract. A request sends no credentials, no query, and no cookie, asks
  for JSON compressed with gzip, follows no redirect, and is never retried.
  A body is at most #{@body_bytes_max} bytes, both as received and once
  expanded.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Compression
  alias Gobusgo.Gbfs.Files

  @connect_timeout_ms 5_000
  @receive_timeout_ms 10_000
  @user_agent "gobusgo"

  @type version :: Files.version()
  @type file :: :vehicle_status | :vehicle_types
  @type system :: %{discovery_urls: %{version() => String.t()}, language: String.t()}
  @type passed_over :: %{
          version: version(),
          reason: :discovery_not_found | :file_not_listed | :file_not_found
        }
  @type cause ::
          Files.cause()
          | {:http_status, pos_integer()}
          | {:unexpected_redirect, pos_integer()}
          | {:transport, term()}
          | {:unsupported_encoding, String.t()}
          | :body_too_large
          | :corrupt_encoding
          | :invalid_json
          | :feed_url_not_https
  @type failure ::
          %{cause: :deadline_exceeded}
          | %{cause: cause(), version: version(), file: :discovery | file()}
  @type fetched :: %{
          optional(:vehicles) => [Files.vehicle()],
          optional(:vehicle_types) => [Files.vehicle_type()],
          kind: :fetched,
          version: version(),
          url: String.t(),
          body: binary(),
          fetched_at: DateTime.t(),
          last_updated: DateTime.t(),
          ttl: non_neg_integer(),
          passed_over: [passed_over()]
        }
  @type not_published :: %{kind: :not_published, passed_over: [passed_over()]}

  @doc "The most bytes a response body may hold, as received and once expanded."
  @spec body_bytes_max() :: pos_integer()
  def body_bytes_max, do: @body_bytes_max

  @doc """
  Fetches `file` of `system`, trying each version newest first.

  `system.discovery_urls` maps each version the system publishes, among
  #{inspect(Files.versions())}, to the HTTPS address of its `gbfs.json`, and
  `system.language` names the language a 1.0 or 2.2 discovery file is read
  in. `:vehicle_types` is tried only in #{inspect(Files.vehicle_types_versions())}.

  A version is passed over, and the next one tried, when its discovery file
  answers 404, when the discovery file lists no such file, or when the file
  answers 404. Any other outcome ends the fetch.

  Returns:

    * `{:ok, %{kind: :fetched}}`: the version that answered, the file's
      address and body as received, `fetched_at` from the clock, the file's
      `last_updated` and `ttl`, its records as `:vehicles` or
      `:vehicle_types` (see `Gobusgo.Gbfs.Files`), and the versions passed
      over before it
    * `{:ok, %{kind: :not_published}}`: every version was passed over
    * `{:error, %{cause: :deadline_exceeded}}`: the fetch outlasted
      `:deadline_ms`
    * `{:error, %{cause: cause, version: version, file: file}}`: the request
      for `file`, `:discovery` or the file asked for, failed with `cause`

  Options: `:deadline_ms`, required, the bound on every request of the
  fetch together; `:versions`, the versions to try, among those the system
  names, which is every one of them by default; `:clock`, a zero-arity
  function returning the current UTC `DateTime`; and `:plug`, a Req plug
  that answers in place of the network.
  """
  @spec fetch(system(), file(), Keyword.t()) ::
          {:ok, fetched() | not_published()} | {:error, failure()}
  def fetch(%{discovery_urls: discovery_urls, language: language} = system, file, options)
      when is_map(discovery_urls) and is_binary(language) and file in @files and is_list(options) do
    options =
      Keyword.validate!(options, [
        :deadline_ms,
        versions: nil,
        clock: &DateTime.utc_now/0,
        plug: nil
      ])

    deadline_ms = Keyword.get(options, :deadline_ms)

    Assert.condition(
      is_integer(deadline_ms),
      "deadline_ms must be an integer, got: #{inspect(deadline_ms)}"
    )

    Assert.condition(deadline_ms > 0, "deadline_ms must be positive, got: #{deadline_ms}")
    clock = Keyword.fetch!(options, :clock)
    Assert.condition(is_function(clock, 0), "clock must be a zero-arity function")
    assert_discovery_urls(discovery_urls)

    context = %{system: system, file: file, clock: clock, plug: Keyword.fetch!(options, :plug)}

    versions =
      versions(%{system: system, file: file, versions: Keyword.fetch!(options, :versions)})

    # The fetch runs in a task so that the deadline bounds every request
    # together.
    task = Task.async(fn -> fetch_versions(versions, context) end)

    case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} ->
        outcome

      nil ->
        {:error, %{cause: :deadline_exceeded}}

      {:exit, reason} ->
        raise Assert.AssertionError, message: "fetch task exited: #{inspect(reason)}"
    end
  end

  defp assert_discovery_urls(discovery_urls) do
    Assert.condition(map_size(discovery_urls) > 0, "a system names at least one version")

    Enum.each(discovery_urls, fn {version, url} ->
      Assert.condition(
        version in Files.versions(),
        "a version is one of #{inspect(Files.versions())}, got: #{inspect(version)}"
      )

      Assert.condition(https?(url), "the #{version} discovery address must use HTTPS")
    end)
  end

  defp versions(%{system: system, file: file, versions: requested}) do
    named = Map.keys(system.discovery_urls)

    requested =
      case requested do
        nil -> named
        versions when is_list(versions) -> versions
      end

    Enum.each(requested, fn version ->
      Assert.condition(version in named, "the system names no version #{inspect(version)}")
    end)

    file_versions =
      case file do
        :vehicle_status -> Files.versions()
        :vehicle_types -> Files.vehicle_types_versions()
      end

    Enum.filter(file_versions, &(&1 in requested))
  end

  defp fetch_versions(versions, context) do
    outcome =
      Enum.reduce_while(versions, {:passed_over, []}, fn version, {:passed_over, passed_over} ->
        case fetch_version(version, context) do
          {:fetched, fetched} ->
            result = Map.merge(fetched, %{kind: :fetched, version: version})
            {:halt, {:fetched, result, passed_over}}

          {:passed_over, reason} ->
            {:cont, {:passed_over, [%{version: version, reason: reason} | passed_over]}}

          {:failed, file, cause} ->
            {:halt, {:failed, %{cause: cause, version: version, file: file}}}
        end
      end)

    case outcome do
      {:fetched, result, passed_over} ->
        {:ok, Map.put(result, :passed_over, Enum.reverse(passed_over))}

      {:passed_over, passed_over} ->
        {:ok, %{kind: :not_published, passed_over: Enum.reverse(passed_over)}}

      {:failed, failure} ->
        {:error, failure}
    end
  end

  defp fetch_version(version, context) do
    discovery_url = Map.fetch!(context.system.discovery_urls, version)

    case get(discovery_url, context) do
      {:ok, body} -> read_discovery(%{version: version, body: body}, context)
      :not_found -> {:passed_over, :discovery_not_found}
      {:error, cause} -> {:failed, :discovery, cause}
    end
  end

  defp read_discovery(%{version: version, body: body}, context) do
    with {:ok, document} <- decode(body),
         {:ok, %{feeds: feeds}} <-
           Files.discovery(%{
             version: version,
             document: document,
             language: context.system.language
           }) do
      case Map.fetch(feeds, feed_name(context.file, version)) do
        {:ok, url} -> fetch_file(%{version: version, url: url}, context)
        :error -> {:passed_over, :file_not_listed}
      end
    else
      {:error, cause} -> {:failed, :discovery, cause}
    end
  end

  defp fetch_file(%{version: version, url: url}, context) do
    if https?(url) do
      case get(url, context) do
        {:ok, body} ->
          read_file(
            %{version: version, url: url, body: body, fetched_at: context.clock.()},
            context
          )

        :not_found ->
          {:passed_over, :file_not_found}

        {:error, cause} ->
          {:failed, context.file, cause}
      end
    else
      {:failed, context.file, :feed_url_not_https}
    end
  end

  defp read_file(%{version: version, body: body} = received, context) do
    parsed =
      with {:ok, document} <- decode(body) do
        case context.file do
          :vehicle_status -> Files.vehicle_status(%{version: version, document: document})
          :vehicle_types -> Files.vehicle_types(%{version: version, document: document})
        end
      end

    case parsed do
      {:ok, records} ->
        {:fetched, Map.merge(records, Map.take(received, [:url, :body, :fetched_at]))}

      {:error, cause} ->
        {:failed, context.file, cause}
    end
  end

  defp feed_name(:vehicle_status, version), do: Files.vehicle_status_name(version)
  defp feed_name(:vehicle_types, _version), do: "vehicle_types"

  defp decode(body) do
    case JSON.decode(body) do
      {:ok, document} -> {:ok, document}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp https?(url), do: is_binary(url) and URI.parse(url).scheme == "https"

  # GBFS publishes no status but 200 for a file and 404 for an optional
  # file the system leaves out, so every other status is a failure.
  # https://github.com/MobilityData/gbfs/blob/v3.0/gbfs.md#files — checked 2026-11-08
  defp get(url, context) do
    request_options =
      [
        url: url,
        headers: [
          {"accept", "application/json"},
          {"accept-encoding", "gzip"},
          {"user-agent", @user_agent}
        ],
        decode_body: false,
        compressed: false,
        redirect: false,
        retry: false,
        receive_timeout: @receive_timeout_ms,
        connect_options: [timeout: @connect_timeout_ms],
        into: &collect/2
      ] ++ plug_option(context.plug)

    case Req.get(request_options) do
      {:ok, %Req.Response{private: %{body_too_large: true}}} ->
        {:error, :body_too_large}

      {:ok, %Req.Response{status: 200} = response} ->
        expand(response)

      {:ok, %Req.Response{status: 404}} ->
        :not_found

      {:ok, %Req.Response{status: status}} when status in 300..399 ->
        {:error, {:unexpected_redirect, status}}

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
  defp collect({:data, data}, {request, response}) do
    body = response.body <> data

    if byte_size(body) <= @body_bytes_max do
      {:cont, {request, %{response | body: body}}}
    else
      {:halt, {request, Req.Response.put_private(%{response | body: ""}, :body_too_large, true)}}
    end
  end

  # The request asks for gzip alone, so a body is either as it is or gzip.
  defp expand(%Req.Response{body: body} = response) do
    case Req.Response.get_header(response, "content-encoding") do
      [] ->
        {:ok, body}

      ["identity"] ->
        {:ok, body}

      ["gzip"] ->
        case Compression.decompress(body, @body_bytes_max) do
          {:ok, expanded} -> {:ok, expanded}
          {:error, :too_large} -> {:error, :body_too_large}
          {:error, :corrupt} -> {:error, :corrupt_encoding}
        end

      encodings ->
        {:error, {:unsupported_encoding, Enum.join(encodings, ", ")}}
    end
  end

  defp plug_option(nil), do: []
  defp plug_option(plug), do: [plug: plug]
end
