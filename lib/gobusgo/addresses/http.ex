defmodule Gobusgo.Addresses.Http do
  @connect_timeout_ms 10_000
  @receive_timeout_ms 60_000
  @json_deadline_ms 60_000
  @file_deadline_ms 900_000
  @user_agent "gobusgo"
  @redirect_statuses [301, 302, 303, 307, 308]

  @moduledoc """
  The bounded `GET` requests the county address sources make. A request
  sends no credentials and no cookie, follows no redirect, is never retried,
  and ends within a deadline: #{@json_deadline_ms} ms for `get_json/2` and
  #{@file_deadline_ms} ms for `get_to_file/2`. The scheduler's backoff
  repeats a build whose request failed.

  Every status is returned as data for the caller to branch on, including
  the redirects of #{inspect(@redirect_statuses)}, whose `location` header
  is returned beside the status. Transport faults, a deadline, and a body
  past its bound are returned as errors:

    * `{:transport, reason}`: a network fault such as `:timeout`
    * `:deadline_exceeded`: the request outlasted its deadline
    * `:body_too_large`: the body passed `bytes_max`

  Options: `:plug`, a plug that answers the request in place of the
  network.
  """

  alias Gobusgo.Assert

  @type error :: {:transport, term()} | :deadline_exceeded | :body_too_large

  @doc """
  Requests `request.url` and returns the status, the `location` header or
  `nil`, the `retry-after` header or `nil`, and a body of at most
  `request.bytes_max` bytes.
  """
  @spec get_json(%{url: String.t(), bytes_max: pos_integer()}, keyword()) ::
          {:ok,
           %{
             status: pos_integer(),
             location: String.t() | nil,
             retry_after: String.t() | nil,
             body: binary()
           }}
          | {:error, error()}
  def get_json(%{url: url, bytes_max: bytes_max}, options)
      when is_binary(url) and is_integer(bytes_max) and bytes_max > 0 and is_list(options) do
    assert_https(url)

    run(@json_deadline_ms, fn ->
      case Req.get(request_options(url, options, into: collect_fun(bytes_max))) do
        {:ok, %Req.Response{private: %{body_too_large: true}}} ->
          {:error, :body_too_large}

        {:ok, %Req.Response{status: status, body: body} = response} ->
          {:ok,
           %{
             status: status,
             location: location(response),
             retry_after: retry_after(response),
             body: body
           }}

        {:error, exception} ->
          transport_error(exception)
      end
    end)
  end

  @doc """
  Requests `request.url` and writes the body to `request.path`, a file this
  call creates, at most `request.bytes_max` bytes of it. The body of a
  redirect is not written.

  `request.inspect_headers` is called once with the headers of a `200`
  response before any of its body is written, and returns `:ok` to go on or
  `{:halt, reason}` to stop, which returns `{:halted, reason}` and leaves no
  more than an empty file.
  """
  @spec get_to_file(
          %{
            url: String.t(),
            path: String.t(),
            bytes_max: pos_integer(),
            inspect_headers: (%{String.t() => [String.t()]} -> :ok | {:halt, term()})
          },
          keyword()
        ) ::
          {:ok,
           %{status: pos_integer(), location: String.t() | nil, byte_count: non_neg_integer()}}
          | {:halted, term()}
          | {:error, error()}
  def get_to_file(
        %{url: url, path: path, bytes_max: bytes_max, inspect_headers: inspect_headers},
        options
      )
      when is_binary(url) and is_binary(path) and is_integer(bytes_max) and bytes_max > 0 and
             is_function(inspect_headers, 1) and is_list(options) do
    assert_https(url)

    run(@file_deadline_ms, fn ->
      device = File.open!(path, [:write, :binary])

      try do
        into = file_fun(%{device: device, bytes_max: bytes_max, inspect_headers: inspect_headers})
        outcome = Req.get(request_options(url, options, into: into))
        file_outcome(outcome)
      after
        File.close(device)
      end
    end)
  end

  defp file_outcome({:ok, %Req.Response{private: %{halted: reason}}}), do: {:halted, reason}

  defp file_outcome({:ok, %Req.Response{private: %{body_too_large: true}}}),
    do: {:error, :body_too_large}

  defp file_outcome({:ok, %Req.Response{status: status} = response}) do
    byte_count = Map.get(response.private, :byte_count, 0)
    {:ok, %{status: status, location: location(response), byte_count: byte_count}}
  end

  defp file_outcome({:error, exception}), do: transport_error(exception)

  defp transport_error(%Req.TransportError{reason: reason}), do: {:error, {:transport, reason}}

  defp transport_error(exception) do
    raise Assert.AssertionError,
      message: "unrecognized request failure #{inspect(exception.__struct__)}"
  end

  defp assert_https(url) do
    Assert.condition(String.starts_with?(url, "https://"), "url must use HTTPS")
  end

  # The request runs in a task so that the deadline bounds the connection,
  # every read, and the write of the file together.
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
      connect_options: [timeout: @connect_timeout_ms]
    ] ++ extra ++ plug_option(Keyword.get(options, :plug))
  end

  defp plug_option(nil), do: []
  defp plug_option(plug), do: [plug: plug]

  defp location(response) do
    case Req.Response.get_header(response, "location") do
      [location | _rest] -> location
      [] -> nil
    end
  end

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

  # A redirect's body is dropped; the body of every other status is written
  # after the first chunk's headers have been inspected.
  defp file_fun(%{device: device, bytes_max: bytes_max, inspect_headers: inspect_headers}) do
    fn {:data, data}, {request, response} ->
      if response.status in @redirect_statuses do
        {:cont, {request, response}}
      else
        write_chunk(%{
          data: data,
          request: request,
          response: response,
          device: device,
          bytes_max: bytes_max,
          inspect_headers: inspect_headers
        })
      end
    end
  end

  defp write_chunk(input) do
    %{request: request, response: response} = input
    byte_count = Map.get(response.private, :byte_count, 0)
    is_first = byte_count == 0

    headers_verdict =
      if is_first and response.status == 200 do
        input.inspect_headers.(response.headers)
      else
        :ok
      end

    new_count = byte_count + byte_size(input.data)

    cond do
      match?({:halt, _reason}, headers_verdict) ->
        {:halt, {request, Req.Response.put_private(response, :halted, elem(headers_verdict, 1))}}

      new_count > input.bytes_max ->
        {:halt, {request, Req.Response.put_private(response, :body_too_large, true)}}

      true ->
        :ok = IO.binwrite(input.device, input.data)
        {:cont, {request, Req.Response.put_private(response, :byte_count, new_count)}}
    end
  end
end
