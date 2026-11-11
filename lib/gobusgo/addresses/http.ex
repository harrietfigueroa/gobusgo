defmodule Gobusgo.Addresses.Http do
  @connect_timeout_ms 10_000
  @receive_timeout_ms 60_000
  @json_deadline_ms 60_000
  @user_agent "gobusgo"

  @moduledoc """
  The bounded `GET` request the county address sources make. A request sends
  no credentials and no cookie, follows no redirect, is not retried here,
  and ends within #{@json_deadline_ms} ms.

  Every status is returned as data for the caller to branch on, with the
  `Retry-After` header beside it. Transport faults, a deadline, and a body
  past its bound are returned as errors:

    * `{:transport, reason}`: a network fault such as `:timeout`
    * `:deadline_exceeded`: the request outlasted its deadline
    * `:body_too_large`: the body passed `bytes_max`

  Options: `:plug`, a plug that answers the request in place of the
  network.
  """

  alias Gobusgo.Assert

  @type error :: {:transport, term()} | :deadline_exceeded | :body_too_large

  @doc "The most milliseconds one request takes."
  @spec json_deadline_ms() :: pos_integer()
  def json_deadline_ms, do: @json_deadline_ms

  @doc """
  Requests `request.url` and returns the status, the `Retry-After` header or
  `nil`, and a body of at most `request.bytes_max` bytes.
  """
  @spec get_json(%{url: String.t(), bytes_max: pos_integer()}, keyword()) ::
          {:ok, %{status: pos_integer(), retry_after: String.t() | nil, body: binary()}}
          | {:error, error()}
  def get_json(%{url: url, bytes_max: bytes_max}, options)
      when is_binary(url) and is_integer(bytes_max) and bytes_max > 0 and is_list(options) do
    Assert.condition(String.starts_with?(url, "https://"), "url must use HTTPS")

    run(@json_deadline_ms, fn ->
      case Req.get(request_options(url, options, into: collect_fun(bytes_max))) do
        {:ok, %Req.Response{private: %{body_too_large: true}}} ->
          {:error, :body_too_large}

        {:ok, %Req.Response{status: status, body: body} = response} ->
          {:ok, %{status: status, retry_after: retry_after(response), body: body}}

        {:error, exception} ->
          transport_error(exception)
      end
    end)
  end

  defp transport_error(%Req.TransportError{reason: reason}), do: {:error, {:transport, reason}}

  defp transport_error(exception) do
    raise Assert.AssertionError,
      message: "unrecognized request failure #{inspect(exception.__struct__)}"
  end

  # The request runs in a task so that the deadline bounds the connection and
  # every read together.
  defp run(deadline_ms, callback) do
    task = Task.async(callback)

    case Task.yield(task, deadline_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, outcome} ->
        outcome

      nil ->
        {:error, :deadline_exceeded}

      {:exit, reason} ->
        raise Assert.AssertionError, message: "request task exited: #{inspect(reason)}"
    end
  end

  defp request_options(url, options, extra) do
    [
      url: url,
      headers: [{"user-agent", @user_agent}],
      decode_body: false,
      compressed: false,
      redirect: false,
      retry: false,
      receive_timeout: @receive_timeout_ms,
      connect_options: [timeout: @connect_timeout_ms],
      # A host with no IPv4 route connects over IPv6. Mint tries IPv6
      # first and connects over IPv4 when that attempt fails, each attempt
      # with the connect timeout of its own.
      # https://hexdocs.pm/mint/Mint.HTTP.html#connect/4 — checked 2026-11-11
      inet6: true
    ] ++ extra ++ plug_option(Keyword.get(options, :plug))
  end

  defp plug_option(nil), do: []
  defp plug_option(plug), do: [plug: plug]

  defp retry_after(response) do
    case Req.Response.get_header(response, "retry-after") do
      [retry_after | _rest] -> retry_after
      [] -> nil
    end
  end

  defp collect_fun(bytes_max) do
    fn {:data, data}, {request, response} ->
      body = response.body <> data

      if byte_size(body) <= bytes_max do
        {:cont, {request, %{response | body: body}}}
      else
        {:halt,
         {request, Req.Response.put_private(%{response | body: ""}, :body_too_large, true)}}
      end
    end
  end
end
