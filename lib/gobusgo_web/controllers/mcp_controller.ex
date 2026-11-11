defmodule GobusgoWeb.McpController do
  @request_bytes_max 1_048_576
  @read_chunk_bytes 65_536
  @read_timeout_ms 15_000
  @usage_page "mcp"

  @moduledoc """
  The MCP endpoint at `/mcp`, in the Streamable HTTP transport. It is the
  shell around `GobusgoWeb.Mcp.Server`: it records the request as a usage
  count, reads the body, hands the body and the three MCP headers to the
  server, and writes the status and the JSON body the server decides on.

  Every request is recorded as a page connection of the page `#{@usage_page}`
  that ended as it began, with the facts of its user agent that
  `GobusgoWeb.ConnectionFacts` keeps and no identifier
  (`Gobusgo.Usage.count/2`). A recorder that refuses, or is not running,
  leaves the request unrecorded and answered.

  A request whose `Origin` header does not name the public host is refused
  with a JSON-RPC error before its body is read (`GobusgoWeb.Mcp.Origin`);
  one with no `Origin` proceeds.

  The body is read up to #{@request_bytes_max} bytes. The media type of the
  answer stays `application/json` under an error status, since the body is a
  JSON-RPC error and not problem details. The statuses, headers, and bodies
  are described in `priv/openapi.json`.

  The tools and resources are those the `GobusgoWeb.Mcp` application
  environment names, read on every request.
  """

  use Phoenix.Controller, formats: [:json]

  require Logger

  alias Gobusgo.Config
  alias Gobusgo.Usage
  alias GobusgoWeb.ConnectionFacts
  alias GobusgoWeb.Endpoint
  alias GobusgoWeb.Mcp.Error
  alias GobusgoWeb.Mcp.Origin
  alias GobusgoWeb.Mcp.Registry
  alias GobusgoWeb.Mcp.Server
  alias GobusgoWeb.Problem

  @recorder Usage

  @doc "Answers the JSON-RPC message in the body, or accepts the notification."
  @spec handle(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def handle(conn, _params) do
    record(conn)

    case origin_decision(conn) do
      :allowed -> read_and_answer(conn)
      :refused -> write(conn, Server.failure(Error.origin_refused()))
    end
  end

  @doc "Answers every method but `POST` as not allowed."
  @spec method_not_allowed(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def method_not_allowed(conn, _params) do
    record(conn)

    case origin_decision(conn) do
      :allowed ->
        conn
        |> put_resp_header("allow", "POST")
        |> Problem.respond(%{
          status: 405,
          detail: "The MCP endpoint answers POST and offers no stream."
        })

      :refused ->
        write(conn, Server.failure(Error.origin_refused()))
    end
  end

  defp origin_decision(conn) do
    {:ok, public_host} = Config.public_host()
    Origin.decide(get_req_header(conn, "origin"), public_host)
  end

  defp read_and_answer(conn) do
    read_options = [
      length: @request_bytes_max,
      read_length: @read_chunk_bytes,
      read_timeout: @read_timeout_ms
    ]

    case read_body(conn, read_options) do
      {:ok, body, conn} ->
        input = %{body: body, headers: headers(conn)}
        write(conn, Server.respond(input, registry()))

      {:more, _partial, conn} ->
        write(conn, Server.failure(Error.payload_too_large()))

      {:error, _reason} ->
        write(conn, Server.failure(Error.invalid_request("The request body could not be read")))
    end
  end

  defp write(conn, %{status: 202, body: nil}), do: send_resp(conn, 202, "")

  defp write(conn, %{status: status, body: body}) do
    conn
    |> Endpoint.keep_json_content_type()
    |> put_status(status)
    |> json(body)
  end

  # Each value, or nil for a header that is absent or sent more than once:
  # a repeated header names no one value to check against the body.
  defp headers(conn) do
    %{
      protocol_version: single_header(conn, "mcp-protocol-version"),
      method: single_header(conn, "mcp-method"),
      name: single_header(conn, "mcp-name")
    }
  end

  defp single_header(conn, name) do
    case get_req_header(conn, name) do
      [value] -> value
      _absent_or_repeated -> nil
    end
  end

  defp registry do
    environment = Application.fetch_env!(:gobusgo, GobusgoWeb.Mcp)

    Registry.new(%{
      tools: Keyword.fetch!(environment, :tools),
      resources: Keyword.fetch!(environment, :resources)
    })
  end

  defp record(conn) do
    connection =
      ConnectionFacts.from_connect(%{
        page: @usage_page,
        connect_params: nil,
        user_agent: single_header(conn, "user-agent"),
        host: conn.host
      })

    case Usage.count(@recorder, connection) do
      :ok -> :ok
      {:error, refusal} -> Logger.debug("MCP request not recorded", refusal: refusal)
    end
  end
end
