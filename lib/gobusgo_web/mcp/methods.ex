defmodule GobusgoWeb.Mcp.Methods do
  @moduledoc """
  The methods the MCP endpoint answers, each a function of the request's
  params and the registry. Everything here is pure.

  `initialize` and `ping` belong to the `:legacy` revisions and
  `server/discover` to the `:modern` one; `tools/list`, `tools/call`,
  `resources/list`, and `resources/read` to both. Any other method is method
  not found. A method returns its result without the fields the 2026-07-28
  revision adds to every result, which `GobusgoWeb.Mcp.Server` puts on.
  """

  alias Gobusgo.Assert
  alias Gobusgo.Schema
  alias GobusgoWeb.Mcp.Error
  alias GobusgoWeb.Mcp.Message
  alias GobusgoWeb.Mcp.Registry
  alias GobusgoWeb.Mcp.Revision
  alias GobusgoWeb.Mcp.ServerInfo

  @initialize_schema {:map,
                      %{
                        "protocolVersion" => :string,
                        "capabilities" => {:map, %{}},
                        "clientInfo" => {:map, %{"name" => :string}}
                      }}

  @tool_call_schema {:map, %{"name" => :string, "arguments" => {:optional, {:map, %{}}}}}

  @resource_read_schema {:map, %{"uri" => :string}}

  @tool_result_schema {:map, %{"content" => {:list, {:map, %{}}}}}

  @doc "The result of `request` under `revision`, or the error that answers it."
  @spec call(Message.request(), Revision.revision(), Registry.t()) ::
          {:ok, %{required(String.t()) => term()}} | {:error, Error.t()}
  def call(%{method: method, params: params}, revision, registry) do
    dispatch(revision, method, params, registry)
  end

  defp dispatch(:legacy, "initialize", params, _registry), do: initialize(params)
  # The 2026-07-28 revision removes `ping`, so only a legacy request has it.
  # https://modelcontextprotocol.io/specification/2026-07-28/changelog — checked 2026-11-11
  defp dispatch(:legacy, "ping", _params, _registry), do: {:ok, %{}}
  defp dispatch(:modern, "server/discover", _params, _registry), do: {:ok, discover()}

  defp dispatch(_revision, "tools/list", params, registry) do
    list(params, fn -> %{"tools" => Registry.tool_definitions(registry)} end)
  end

  defp dispatch(_revision, "resources/list", params, registry) do
    list(params, fn -> %{"resources" => Registry.resource_definitions(registry)} end)
  end

  defp dispatch(_revision, "tools/call", params, registry), do: call_tool(params, registry)

  defp dispatch(revision, "resources/read", params, registry) do
    read_resource(params, revision, registry)
  end

  defp dispatch(revision, method, _params, _registry) do
    {:error, Error.method_not_found(method, revision)}
  end

  # The server answers the requested version when it speaks it, and another
  # version it speaks otherwise.
  # https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle#version-negotiation — checked 2026-11-11
  defp initialize(params) do
    case Schema.mismatch(params, @initialize_schema) do
      nil ->
        {:ok,
         %{
           "protocolVersion" => Revision.negotiate(params["protocolVersion"]),
           "capabilities" => ServerInfo.capabilities(),
           "serverInfo" => ServerInfo.implementation(),
           "instructions" => ServerInfo.instructions()
         }}

      %{path: path} ->
        {:error,
         Error.invalid_params("Invalid initialize params at " <> Schema.format_path(path))}
    end
  end

  defp discover do
    %{
      "supportedVersions" => Revision.supported(),
      "capabilities" => ServerInfo.capabilities(),
      "instructions" => ServerInfo.instructions()
    }
  end

  # The server issues no cursor, so every cursor a client sends is invalid.
  # https://modelcontextprotocol.io/specification/2025-11-25/server/utilities/pagination — checked 2026-11-11
  defp list(params, build_result_callback) do
    case is_map_key(params, "cursor") do
      true -> {:error, Error.invalid_params("Invalid cursor")}
      false -> {:ok, build_result_callback.()}
    end
  end

  defp call_tool(params, registry) do
    with nil <- Schema.mismatch(params, @tool_call_schema),
         {:ok, tool} <- fetch_tool(registry, params["name"]),
         arguments = Map.get(params, "arguments", %{}),
         nil <- Schema.mismatch(arguments, tool.arguments_schema()) do
      {:ok, run_tool(tool, arguments)}
    else
      %{path: path} ->
        {:error, Error.invalid_params("Invalid params at " <> Schema.format_path(path))}

      {:error, error} ->
        {:error, error}
    end
  end

  defp fetch_tool(registry, name) do
    case Registry.fetch_tool(registry, name) do
      {:ok, tool} -> {:ok, tool}
      :unknown -> {:error, Error.invalid_params("Unknown tool: " <> name)}
    end
  end

  defp run_tool(tool, arguments) do
    case tool.call(arguments) do
      {:ok, result} ->
        Assert.schema(result, @tool_result_schema)

      {:error, text} when is_binary(text) ->
        %{"content" => [%{"type" => "text", "text" => text}], "isError" => true}
    end
  end

  defp read_resource(params, revision, registry) do
    with nil <- Schema.mismatch(params, @resource_read_schema),
         {:ok, resource} <- fetch_resource(registry, params["uri"], revision),
         {:ok, text} <- read(resource) do
      definition = resource.definition()
      %{"mimeType" => mime_type} = definition
      content = %{"uri" => params["uri"], "mimeType" => mime_type, "text" => text}
      {:ok, %{"contents" => [with_meta(content, definition)]}}
    else
      %{path: path} ->
        {:error, Error.invalid_params("Invalid params at " <> Schema.format_path(path))}

      {:error, error} ->
        {:error, error}
    end
  end

  # A resource's `_meta`, such as the CSP lists of an MCP App, goes on the
  # content as it does on the listing, where the host reads it from.
  # https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx — checked 2026-11-11
  defp with_meta(content, %{"_meta" => meta}), do: Map.put(content, "_meta", meta)
  defp with_meta(content, %{}), do: content

  defp fetch_resource(registry, uri, revision) do
    case Registry.fetch_resource(registry, uri) do
      {:ok, resource} -> {:ok, resource}
      :unknown -> {:error, Error.resource_not_found(uri, revision)}
    end
  end

  defp read(resource) do
    case resource.read() do
      {:ok, text} when is_binary(text) -> {:ok, text}
      {:error, :unavailable} -> {:error, Error.internal_error("The resource is not available")}
    end
  end
end
