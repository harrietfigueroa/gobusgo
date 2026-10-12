defmodule Gobusgo.S3.Client do
  @attempt_count_max 3
  @deadline_ms 15_000
  @connect_timeout_ms 2_000
  @receive_timeout_ms 5_000
  @retry_delay_ms_base 100
  @retry_delay_ms_cap 2_000
  @retry_after_ms_max 5_000

  @moduledoc """
  One signed request to the bucket the application stores in, bounded in
  attempts, time, and the bytes it reads.

  A request makes at most #{@attempt_count_max} attempts and ends within
  #{@deadline_ms} ms, each attempt with #{@connect_timeout_ms} ms to connect
  and #{@receive_timeout_ms} ms between the bytes it receives. It follows no
  redirect. It is signed with AWS Signature Version 4 from the credentials
  its `:credentials` function returns, which are fetched once per request.

  `request/2` returns `{:ok, %{status: status, body: body}}` for every
  response that is not retried away, so a caller branches on the statuses
  its operation documents.

  ## Retries

  The statuses S3 documents as transient are retried: 500, 502, 503, and
  504, and 409, which a conditional write answers while another request on
  the same key is in flight. A network fault is retried when the request's
  `:repeatable` is `true`. A request whose fault leaves it unknown whether
  S3 applied it, and whose second application would answer differently,
  passes `false` and gets the fault back.

  Between attempts the delay is drawn from a window that doubles from
  #{@retry_delay_ms_base} ms to #{@retry_delay_ms_cap} ms, and a
  `Retry-After` header takes the window's place, up to
  #{@retry_after_ms_max} ms.

  ## Errors

    * `{:transport, reason}`: a network fault such as `:timeout`
    * `:deadline_exceeded`: all attempts together outlasted the deadline
    * `:body_too_large`: the response exceeds the request's `:bytes_max`
    * `:credentials_unavailable`: the credentials function returned an error

  ## Options

  Each defaults to its value under `config :gobusgo, Gobusgo.S3`.

    * `:endpoint`: the address of the bucket, scheme and host. With none
      configured it is `endpoint/1` of the configured `:bucket` and
      `:region`.
    * `:region`: the region the requests are signed for.
    * `:credentials`: a zero-arity function returning `{:ok, credentials}`
      or `{:error, reason}`. Defaults to the credentials
      `Gobusgo.S3.Credentials` holds under its own name.
    * `:plug`: a plug that answers the request in place of the network.
    * `:retry_delay_ms_base`: the first retry's delay window.
  """

  alias Gobusgo.Assert
  alias Gobusgo.S3.Credentials

  # https://docs.aws.amazon.com/AmazonS3/latest/API/ErrorResponses.html — checked 2026-10-11
  # https://docs.aws.amazon.com/AmazonS3/latest/userguide/conditional-writes.html — checked 2026-10-11
  @retry_statuses [409, 500, 502, 503, 504]

  @methods [:get, :put, :head, :delete]

  @typedoc """
  `key` is the whole key of an object, or `""` for a request on the bucket.
  `body` is `nil` for a request that sends none.
  """
  @type request :: %{
          method: :get | :put | :head | :delete,
          key: String.t(),
          query: [{String.t(), String.t()}],
          headers: [{String.t(), String.t()}],
          body: binary() | nil,
          bytes_max: pos_integer(),
          repeatable: boolean()
        }

  @type response :: %{status: pos_integer(), body: binary()}

  @type error ::
          {:transport, term()} | :deadline_exceeded | :body_too_large | :credentials_unavailable

  @doc "Sends `request` and returns the response of its last attempt."
  @spec request(request(), Keyword.t()) :: {:ok, response()} | {:error, error()}
  def request(%{method: method, key: key, bytes_max: bytes_max} = request, options)
      when is_binary(key) and is_list(options) do
    Assert.condition(method in @methods, "method must be one of #{inspect(@methods)}")
    Assert.condition(is_integer(bytes_max), "bytes_max must be an integer")
    Assert.condition(bytes_max > 0, "bytes_max must be positive, got: #{bytes_max}")
    Assert.condition(is_boolean(request.repeatable), "repeatable must be a boolean")
    settings = settings(options)

    case settings.credentials.() do
      {:ok, credentials} ->
        # The request runs in a task so that the deadline bounds every
        # attempt and every wait between attempts together.
        task = Task.async(fn -> send_request(request, credentials, settings) end)

        case Task.yield(task, @deadline_ms) || Task.shutdown(task, :brutal_kill) do
          {:ok, outcome} ->
            outcome

          nil ->
            {:error, :deadline_exceeded}

          {:exit, reason} ->
            raise Assert.AssertionError, message: "request task exited: #{inspect(reason)}"
        end

      {:error, _reason} ->
        {:error, :credentials_unavailable}
    end
  end

  @doc """
  The address S3 serves `location.bucket` at in `location.region`: the
  bucket's virtual-hosted regional endpoint.
  """
  @spec endpoint(%{bucket: String.t(), region: String.t()}) :: String.t()
  def endpoint(%{bucket: bucket, region: region}) when is_binary(bucket) and is_binary(region) do
    "https://" <> bucket <> ".s3." <> region <> ".amazonaws.com"
  end

  defp settings(options) do
    configured = Application.get_env(:gobusgo, Gobusgo.S3, [])
    region = setting(options, configured, :region)

    endpoint =
      case setting(options, configured, :endpoint) do
        nil -> endpoint(%{bucket: Keyword.get(configured, :bucket), region: region})
        endpoint -> endpoint
      end

    credentials = Keyword.get(options, :credentials, &held_credentials/0)
    Assert.condition(is_binary(endpoint), "endpoint must be configured")
    Assert.condition(is_binary(region), "region must be configured")
    Assert.condition(is_function(credentials, 0), "credentials must be a zero-arity function")

    %{
      endpoint: endpoint,
      region: region,
      credentials: credentials,
      plug: Keyword.get(options, :plug),
      retry_delay_ms_base: Keyword.get(options, :retry_delay_ms_base, @retry_delay_ms_base)
    }
  end

  defp setting(options, configured, key) do
    Keyword.get_lazy(options, key, fn -> Keyword.get(configured, key) end)
  end

  defp held_credentials, do: Credentials.fetch(Credentials)

  defp send_request(request, credentials, settings) do
    request_options =
      [
        method: request.method,
        url: settings.endpoint <> "/" <> request.key,
        params: request.query,
        headers: request.headers,
        body: request.body,
        aws_sigv4: [
          access_key_id: credentials.access_key_id,
          secret_access_key: credentials.secret_access_key,
          token: credentials.token,
          service: :s3,
          region: settings.region
        ],
        decode_body: false,
        compressed: false,
        redirect: false,
        retry: &retry(&1, &2, %{request: request, settings: settings}),
        max_retries: @attempt_count_max - 1,
        retry_log_level: false,
        receive_timeout: @receive_timeout_ms,
        connect_options: [timeout: @connect_timeout_ms],
        into: &collect(&1, &2, request.bytes_max)
      ] ++ plug_option(settings.plug)

    case Req.request(request_options) do
      {:ok, %Req.Response{private: %{body_too_large: true}}} ->
        {:error, :body_too_large}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:ok, %{status: status, body: body}}

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
  defp retry(request, %Req.Response{status: status} = response, context) do
    if status in @retry_statuses do
      case retry_after_ms(response) do
        nil -> {:delay, jittered_delay_ms(request, context.settings.retry_delay_ms_base)}
        retry_after_ms -> {:delay, min(retry_after_ms, @retry_after_ms_max)}
      end
    else
      false
    end
  end

  defp retry(request, %Req.TransportError{}, context) do
    if context.request.repeatable do
      {:delay, jittered_delay_ms(request, context.settings.retry_delay_ms_base)}
    else
      false
    end
  end

  defp retry(_request, %{__exception__: true}, _context), do: false

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
