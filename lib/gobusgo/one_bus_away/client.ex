defmodule Gobusgo.OneBusAway.Client do
  @moduledoc """
  The one place that talks HTTP to a OneBusAway server. The API key travels in
  the query string, so every value this module returns has the key scrubbed and
  no request struct or URL ever leaves it.

  `get/3` returns the HTTP status and the raw body as data, or a transport
  failure as data. Retries, timeouts, and the total deadline are explicit.

  Every attempt, a retry included, takes a permit from the request gate
  first and releases it with the attempt's outcome. Waiting for a permit
  counts against the total deadline, and a caller the gate turns away gets
  `:rate_limited`. A 429 response is released as rate-limited, which pauses
  the gate, and is returned without a retry.
  """

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.RequestGate

  @type settings :: Gobusgo.Config.OneBusAway.t()
  @type response :: %{status: non_neg_integer(), body: binary()}
  @type failure :: {:transport, term()} | :deadline_exceeded | :rate_limited

  @connect_timeout_ms 5_000
  @deadline_ms_default 30_000
  @gate_default RequestGate
  @gate_permit_key :gobusgo_gate_permit
  @gate_wait_margin_ms 250
  @receive_timeout_ms 10_000
  @retries_default 2
  @retry_delay_ms_base_default 500
  @retry_delay_ms_cap 4_000
  @retry_statuses [408, 500, 502, 503, 504]
  @retry_transport_reasons [:timeout, :econnrefused, :closed]

  defmodule RateLimitedError do
    @moduledoc false
    defexception message: "the request gate granted no permit"
  end

  @doc """
  Issues a GET for `path` on the configured server and returns the status and
  body. Options: `:params`, the query parameters sent beside the key, as a
  keyword list that never names `key`; `:plug` (a Req plug, for tests),
  `:max_retries`, `:retry_delay_ms_base`, `:deadline_ms`, the bound on all
  attempts and every wait for a permit together, and `:gate`, the request
  gate, which is `#{inspect(@gate_default)}` by default.

  The wait for a permit ends #{@gate_wait_margin_ms} ms before the deadline,
  the least time left in which a request is still worth starting.
  """
  @spec get(settings(), String.t(), Keyword.t()) :: {:ok, response()} | {:error, failure()}
  def get(%{base_url: base_url, api_key: api_key} = settings, path, options)
      when is_binary(base_url) and is_binary(api_key) and is_binary(path) and is_list(options) do
    Assert.condition(
      is_struct(settings, Gobusgo.Config.OneBusAway),
      "settings must be a Gobusgo.Config.OneBusAway"
    )

    options =
      Keyword.validate!(options,
        params: [],
        plug: nil,
        max_retries: @retries_default,
        retry_delay_ms_base: @retry_delay_ms_base_default,
        deadline_ms: @deadline_ms_default,
        gate: @gate_default
      )

    params = Keyword.fetch!(options, :params)
    Assert.condition(Keyword.keyword?(params), "params must be a keyword list")
    Assert.condition(not Keyword.has_key?(params, :key), "params must not name the key parameter")
    deadline_ms = Keyword.fetch!(options, :deadline_ms)
    Assert.condition(deadline_ms > 0, "deadline_ms must be positive, got #{deadline_ms}")
    permit_deadline_at_ms = now_ms() + deadline_ms - @gate_wait_margin_ms
    options = Keyword.put(options, :permit_deadline_at_ms, permit_deadline_at_ms)

    task = Task.async(fn -> request(base_url, api_key, path, options) end)

    case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} -> scrub_outcome(outcome, api_key)
      nil -> {:error, :deadline_exceeded}
      {:exit, _reason} -> raise Assert.AssertionError, message: "request task exited"
    end
  end

  @doc """
  Returns the host name of the configured server, without scheme, port, path,
  or user information.
  """
  @spec host(settings()) :: String.t()
  def host(%{base_url: base_url}) when is_binary(base_url) do
    host = URI.parse(base_url).host
    Assert.condition(is_binary(host), "base_url must name a host")
    Assert.condition(host != "", "base_url must name a non-empty host")
    host
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
        params: Keyword.fetch!(options, :params) ++ [key: api_key],
        headers: [accept: "application/json"],
        decode_body: false,
        redirect: false,
        retry: &retry?/2,
        max_retries: Keyword.fetch!(options, :max_retries),
        retry_delay: &retry_delay_ms(&1, base_delay_ms),
        retry_log_level: false,
        receive_timeout: @receive_timeout_ms,
        connect_options: [timeout: @connect_timeout_ms],
        # A host with no IPv4 route connects over IPv6. Mint tries IPv6
        # first and connects over IPv4 when that attempt fails, each attempt
        # with the connect timeout of its own.
        # https://hexdocs.pm/mint/Mint.HTTP.html#connect/4 — checked 2026-10-06
        inet6: true
      ] ++ plug_option(Keyword.fetch!(options, :plug))

    gate = Keyword.fetch!(options, :gate)
    permit_deadline_at_ms = Keyword.fetch!(options, :permit_deadline_at_ms)

    try do
      request =
        request_options
        |> Req.new()
        |> Req.Request.prepend_request_steps(
          gate_acquire: &acquire_permit(&1, gate, permit_deadline_at_ms)
        )
        |> Req.Request.prepend_response_steps(gate_release: &release_permit(&1, gate))
        |> Req.Request.prepend_error_steps(gate_release: &release_permit(&1, gate))

      case Req.get(request) do
        {:ok, %Req.Response{status: status, body: body}} -> {:ok, %{status: status, body: body}}
        {:error, %Req.TransportError{reason: reason}} -> {:error, {:transport, reason}}
        {:error, %RateLimitedError{}} -> {:error, :rate_limited}
        {:error, exception} -> {:raised, exception.__struct__}
      end
    rescue
      exception -> {:raised, exception.__struct__}
    end
  end

  # Req runs its request steps again for every retry, so each attempt takes
  # its own permit. A halted request skips the adapter and every later step.
  defp acquire_permit(request, gate, permit_deadline_at_ms) do
    wait_ms = max(permit_deadline_at_ms - now_ms(), 0)

    case RequestGate.acquire(gate, wait_ms) do
      {:ok, permit} -> Req.Request.put_private(request, @gate_permit_key, permit)
      {:error, :rate_limited} -> Req.Request.halt(request, %RateLimitedError{})
    end
  end

  # These steps run ahead of Req's retry step, so the permit of an attempt
  # is released before the delay that precedes the next one.
  defp release_permit({request, response_or_exception}, gate) do
    permit = Req.Request.get_private(request, @gate_permit_key)
    Assert.condition(is_reference(permit), "an attempt must hold a permit")

    outcome =
      case response_or_exception do
        # OneBusAway documents no 429 and no Retry-After; the gate treats one
        # as rate limiting on the project owner's statement that limits exist.
        # https://developer.onebusaway.org/api/where — checked 2026-10-03
        %Req.Response{status: 429} = response ->
          {:rate_limited, retry_after_ms(response)}

        %Req.Response{} ->
          :completed

        %{__exception__: true} ->
          :failed
      end

    :ok = RequestGate.release(gate, %{permit: permit, outcome: outcome})
    {request, response_or_exception}
  end

  # A Retry-After value that is malformed or in the past names no time, and
  # the gate then backs off on its own.
  defp retry_after_ms(response) do
    case Req.Response.get_retry_after(response) do
      retry_after_ms when is_integer(retry_after_ms) -> max(retry_after_ms, 0)
      nil -> nil
    end
  rescue
    _exception -> nil
  end

  # A 429 is left to the gate, which pauses every caller; repeating the
  # request here would spend the budget the pause protects.
  defp retry?(_request, %Req.Response{status: status}), do: status in @retry_statuses

  defp retry?(_request, %Req.TransportError{reason: reason}) do
    reason in @retry_transport_reasons
  end

  defp retry?(_request, %{__exception__: true}), do: false

  defp now_ms, do: System.monotonic_time(:millisecond)

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
