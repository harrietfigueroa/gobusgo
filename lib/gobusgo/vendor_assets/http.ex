defmodule Gobusgo.VendorAssets.Http do
  @attempt_count_max 3
  @deadline_ms 120_000

  @moduledoc """
  The bounded `GET` request the vendored asset sources share. A request
  makes at most #{@attempt_count_max} attempts and ends within
  #{@deadline_ms} milliseconds, follows no redirect, and reads at most the
  bytes its caller allows.

  `get/2` returns `{:ok, %{status: status, body: body, location: location}}`
  for every response that is not retried away, so a caller branches on the
  status its source documents; `location` is the `location` header or `nil`.

  Errors:

    * `{:transport, reason}`: a network fault such as `:timeout`
    * `:deadline_exceeded`: all attempts together outlasted the deadline
    * `:body_too_large`: the response exceeds `bytes_max`

  Options: `:plug`, a plug that answers the request in place of the network,
  and `:retry_delay_ms_base`, the first retry's delay window.
  """

  alias Gobusgo.Assert

  @connect_timeout_ms 10_000
  @receive_timeout_ms 30_000
  @retry_delay_ms_base 500
  @retry_delay_ms_cap 8_000
  @retry_after_ms_max 30_000
  @retry_statuses [408, 429, 500, 502, 503, 504]

  @type response :: %{status: pos_integer(), body: binary(), location: String.t() | nil}
  @type error :: {:transport, term()} | :deadline_exceeded | :body_too_large

  @doc """
  Requests `request.url` with `request.headers` and returns the response
  with a body of at most `request.bytes_max` bytes.
  """
  @spec get(
          %{url: String.t(), headers: [{String.t(), String.t()}], bytes_max: pos_integer()},
          keyword()
        ) ::
          {:ok, response()} | {:error, error()}
  def get(%{url: url, headers: headers, bytes_max: bytes_max}, options)
      when is_binary(url) and is_list(headers) and is_integer(bytes_max) and is_list(options) do
    Assert.condition(String.starts_with?(url, "https://"), "url must use HTTPS")
    Assert.condition(bytes_max > 0, "bytes_max must be positive, got: #{bytes_max}")

    # The request runs in a task so that the deadline bounds every attempt
    # and every wait between attempts together.
    task = Task.async(fn -> request(url, headers, bytes_max, options) end)

    case Task.yield(task, @deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} ->
        outcome

      nil ->
        {:error, :deadline_exceeded}

      {:exit, reason} ->
        raise Assert.AssertionError, message: "request task exited: #{inspect(reason)}"
    end
  end

  defp request(url, headers, bytes_max, options) do
    delay_ms_base = Keyword.get(options, :retry_delay_ms_base, @retry_delay_ms_base)

    request_options =
      [
        url: url,
        headers: headers,
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

      {:ok, %Req.Response{status: status, body: body} = response} ->
        {:ok, %{status: status, body: body, location: location(response)}}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, {:transport, reason}}

      {:error, exception} ->
        raise Assert.AssertionError,
          message: "unrecognized request failure #{inspect(exception.__struct__)}"
    end
  end

  defp location(response) do
    case Req.Response.get_header(response, "location") do
      [location | _rest] -> location
      [] -> nil
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
