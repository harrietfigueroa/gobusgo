defmodule Gobusgo.OneBusAway.Client do
  @moduledoc """
  The one place that talks HTTP to a OneBusAway server. The API key travels in
  the query string, so every value this module returns has the key scrubbed and
  no request struct or URL ever leaves it.

  `get/3` returns the HTTP status and the raw body as data, or a transport
  failure as data. Retries, timeouts, and the total deadline are explicit.
  """

  alias Gobusgo.Assert

  @type settings :: %{base_url: String.t(), api_key: String.t()}
  @type response :: %{status: non_neg_integer(), body: binary()}
  @type failure :: {:transport, term()} | :deadline_exceeded

  @connect_timeout_ms 5_000
  @deadline_ms_default 30_000
  @receive_timeout_ms 10_000
  @retries_default 2
  @retry_delay_ms_base_default 500
  @retry_delay_ms_cap 4_000

  @doc """
  Issues a GET for `path` on the configured server and returns the status and
  body. Options: `:plug` (a Req plug, for tests), `:max_retries`,
  `:retry_delay_ms_base`, and `:deadline_ms`, the bound on all attempts together.
  """
  @spec get(settings(), String.t(), Keyword.t()) :: {:ok, response()} | {:error, failure()}
  def get(%{base_url: base_url, api_key: api_key}, path, options)
      when is_binary(base_url) and is_binary(api_key) and is_binary(path) and is_list(options) do
    options =
      Keyword.validate!(options,
        plug: nil,
        max_retries: @retries_default,
        retry_delay_ms_base: @retry_delay_ms_base_default,
        deadline_ms: @deadline_ms_default
      )

    deadline_ms = Keyword.fetch!(options, :deadline_ms)
    Assert.condition(deadline_ms > 0, "deadline_ms must be positive, got #{deadline_ms}")

    task = Task.async(fn -> request(base_url, api_key, path, options) end)

    case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} -> scrub_outcome(outcome, api_key)
      nil -> {:error, :deadline_exceeded}
      {:exit, _reason} -> raise Assert.AssertionError, message: "request task exited"
    end
  end

  @doc "Replaces every occurrence of `secret` inside `term` with a placeholder."
  @spec scrub(term(), String.t()) :: term()
  def scrub(term, secret) when is_binary(secret) and secret != "" do
    case term do
      text when is_binary(text) ->
        String.replace(text, secret, "[REDACTED]")

      tuple when is_tuple(tuple) ->
        tuple |> Tuple.to_list() |> scrub(secret) |> List.to_tuple()

      list when is_list(list) ->
        Enum.map(list, &scrub(&1, secret))

      map when is_map(map) ->
        Map.new(map, fn {key, value} -> {scrub(key, secret), scrub(value, secret)} end)

      other ->
        other
    end
  end

  # The task rescues every exception and returns only its module name: a
  # crashing task would put the request, and with it the key, in a crash report.
  defp request(base_url, api_key, path, options) do
    base_delay_ms = Keyword.fetch!(options, :retry_delay_ms_base)

    request_options =
      [
        base_url: base_url,
        url: path,
        params: [key: api_key],
        headers: [accept: "application/json"],
        decode_body: false,
        redirect: false,
        retry: :transient,
        max_retries: Keyword.fetch!(options, :max_retries),
        retry_delay: &retry_delay_ms(&1, base_delay_ms),
        retry_log_level: false,
        receive_timeout: @receive_timeout_ms,
        connect_options: [timeout: @connect_timeout_ms]
      ] ++ plug_option(Keyword.fetch!(options, :plug))

    try do
      case Req.get(request_options) do
        {:ok, %Req.Response{status: status, body: body}} -> {:ok, %{status: status, body: body}}
        {:error, %Req.TransportError{reason: reason}} -> {:error, {:transport, reason}}
        {:error, exception} -> {:raised, exception.__struct__}
      end
    rescue
      exception -> {:raised, exception.__struct__}
    end
  end

  defp plug_option(nil), do: []
  defp plug_option(plug), do: [plug: plug]

  # Full jitter over an exponential window, so synchronized callers spread out.
  defp retry_delay_ms(retry_count, base_delay_ms) do
    window_ms = min(@retry_delay_ms_cap, base_delay_ms * Integer.pow(2, retry_count))
    :rand.uniform(max(window_ms, 1))
  end

  defp scrub_outcome({:ok, response}, _api_key), do: {:ok, response}
  defp scrub_outcome({:error, failure}, api_key), do: {:error, scrub(failure, api_key)}

  defp scrub_outcome({:raised, module}, _api_key) do
    raise Assert.AssertionError, message: "unrecognized request failure #{inspect(module)}"
  end
end
