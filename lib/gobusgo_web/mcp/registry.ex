defmodule GobusgoWeb.Mcp.Registry do
  @moduledoc """
  The tools and resources the MCP endpoint serves, built from the modules the
  `GobusgoWeb.Mcp` application environment names under `:tools`, which
  implement `GobusgoWeb.Mcp.Tool`, and `:resources`, which implement
  `GobusgoWeb.Mcp.Resource`. Everything here is pure.

  A registry lists its tools by name and its resources by uri, so a list
  answers in the same order while the registry is unchanged. A name or a uri
  held twice, and a module that does not implement its contract, fail at
  `new/1` as the programmer errors they are.
  """

  alias Gobusgo.Assert

  @opaque t :: %{
            tools: %{String.t() => module()},
            resources: %{String.t() => module()}
          }

  @doc "The registry of `tools` and `resources`, lists of modules."
  @spec new(%{tools: [module()], resources: [module()]}) :: t()
  def new(%{tools: tools, resources: resources}) when is_list(tools) and is_list(resources) do
    %{
      tools: index(tools, GobusgoWeb.Mcp.Tool, "name", "tool name"),
      resources: index(resources, GobusgoWeb.Mcp.Resource, "uri", "resource uri")
    }
  end

  @doc "The definition of every tool, sorted by name."
  @spec tool_definitions(t()) :: [%{required(String.t()) => term()}]
  def tool_definitions(%{tools: tools}), do: definitions(tools)

  @doc "The definition of every resource, sorted by uri."
  @spec resource_definitions(t()) :: [%{required(String.t()) => term()}]
  def resource_definitions(%{resources: resources}), do: definitions(resources)

  @doc "The module of the tool named `name`."
  @spec fetch_tool(t(), String.t()) :: {:ok, module()} | :unknown
  def fetch_tool(%{tools: tools}, name) when is_binary(name), do: fetch(tools, name)

  @doc "The module of the resource at `uri`."
  @spec fetch_resource(t(), String.t()) :: {:ok, module()} | :unknown
  def fetch_resource(%{resources: resources}, uri) when is_binary(uri), do: fetch(resources, uri)

  defp fetch(modules, key) do
    case Map.fetch(modules, key) do
      {:ok, module} -> {:ok, module}
      :error -> :unknown
    end
  end

  defp definitions(modules) do
    modules
    |> Enum.sort()
    |> Enum.map(fn {_key, module} -> module.definition() end)
  end

  defp index(modules, behaviour, key_field, key_label) do
    Enum.reduce(modules, %{}, fn module, index ->
      Assert.condition(
        implements?(module, behaviour),
        "#{inspect(module)} must implement #{inspect(behaviour)}"
      )

      %{^key_field => key} = module.definition()
      Assert.condition(is_binary(key) and key != "", "#{key_label} must be a non-empty string")
      Assert.condition(not is_map_key(index, key), "duplicate #{key_label}: #{key}")
      Map.put(index, key, module)
    end)
  end

  defp implements?(module, behaviour) do
    Code.ensure_loaded?(module) and
      behaviour in Keyword.get(module.module_info(:attributes), :behaviour, [])
  end
end
