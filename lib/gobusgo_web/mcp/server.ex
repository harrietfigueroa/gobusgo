defmodule GobusgoWeb.Mcp.Server do
  @moduledoc """
  The decision of the MCP endpoint: from the body of a request and the three
  MCP headers it carries, the status and the JSON-RPC body to answer with.
  Everything here is pure, so the controller that reads the request and
  writes the response holds no decision of its own.

  `respond/2` answers a notification with status `202` and no body, a request
  that succeeds with `200` and a `result`, and every outcome the protocol
  names, a body that is not JSON, an unknown method, an unknown tool, a
  header that disagrees with the body, with a JSON-RPC `error` under the
  status `GobusgoWeb.Mcp.Error` gives it. The answer is always one JSON
  object and never a stream.

  A result under the 2026-07-28 revision carries `resultType`, the server's
  name and version in `_meta`, and, for the methods the revision makes
  cacheable, a `ttlMs` and a `cacheScope`.
  """

  alias GobusgoWeb.Mcp.Error
  alias GobusgoWeb.Mcp.Message
  alias GobusgoWeb.Mcp.Methods
  alias GobusgoWeb.Mcp.Registry
  alias GobusgoWeb.Mcp.Revision
  alias GobusgoWeb.Mcp.ServerInfo

  @type input :: %{body: binary(), headers: Revision.headers()}

  @type response :: %{status: pos_integer(), body: %{required(String.t()) => term()} | nil}

  @server_info_key "io.modelcontextprotocol/serverInfo"

  # The registry is fixed for the life of a deploy, so a listing is fresh for
  # as long as a client may hold it; a resource's content is the resource's to
  # age, so a read is stale at once.
  # https://modelcontextprotocol.io/specification/2026-07-28/server/utilities/caching — checked 2026-11-11
  @listing_ttl_ms 300_000
  @read_ttl_ms 0
  @cache_ttl_ms_by_method %{
    "server/discover" => @listing_ttl_ms,
    "tools/list" => @listing_ttl_ms,
    "resources/list" => @listing_ttl_ms,
    "resources/read" => @read_ttl_ms
  }

  @doc "The status and the body that answer `input`, with the tools and resources of `registry`."
  @spec respond(input(), Registry.t()) :: response()
  def respond(%{body: body, headers: headers}, registry) when is_binary(body) do
    case Message.parse(body) do
      {:error, %{error: error, id: id}} -> failure(error, id)
      {:ok, %{kind: :notification}} -> %{status: 202, body: nil}
      {:ok, %{kind: :request} = request} -> answer(request, headers, registry)
    end
  end

  @doc "The status and the body for an `error` that arose before any message was read."
  @spec failure(Error.t()) :: response()
  def failure(error), do: failure(error, nil)

  defp answer(request, headers, registry) do
    with {:ok, revision} <- Revision.resolve(request, headers),
         {:ok, result} <- Methods.call(request, revision, registry) do
      success(finish(result, revision, request.method), request.id)
    else
      {:error, error} -> failure(error, request.id)
    end
  end

  defp success(result, id) do
    %{status: 200, body: %{"jsonrpc" => "2.0", "id" => id, "result" => result}}
  end

  defp failure(%{status: status} = error, id) do
    %{status: status, body: Error.to_body(error, id)}
  end

  defp finish(result, :legacy, _method), do: result

  defp finish(result, :modern, method) do
    server_info = %{@server_info_key => ServerInfo.implementation()}

    result
    |> Map.put("resultType", "complete")
    |> Map.update("_meta", server_info, &Map.merge(&1, server_info))
    |> put_cache_hints(method)
  end

  defp put_cache_hints(result, method) do
    case Map.fetch(@cache_ttl_ms_by_method, method) do
      {:ok, ttl_ms} -> Map.merge(result, %{"ttlMs" => ttl_ms, "cacheScope" => "public"})
      :error -> result
    end
  end
end
