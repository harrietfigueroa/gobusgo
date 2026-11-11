defmodule GobusgoWeb.Mcp.RegistryTest do
  # Builds registries from the fake tools and resources of the test support
  # and reads them back in the order a list answers in.
  use ExUnit.Case, async: true

  alias Gobusgo.Test.McpFakes.EchoTool
  alias Gobusgo.Test.McpFakes.NoticeResource
  alias Gobusgo.Test.McpFakes.RefusingTool
  alias Gobusgo.Test.McpFakes.UnavailableResource
  alias GobusgoWeb.Mcp.Registry

  describe "new/1" do
    test "lists the tools sorted by name, whatever order they are configured in" do
      registry = Registry.new(%{tools: [EchoTool, RefusingTool], resources: []})

      assert for(%{"name" => name} <- Registry.tool_definitions(registry), do: name) ==
               ["alpha_refuse", "echo"]
    end

    test "lists the resources sorted by uri" do
      registry = Registry.new(%{tools: [], resources: [UnavailableResource, NoticeResource]})

      assert for(%{"uri" => uri} <- Registry.resource_definitions(registry), do: uri) ==
               ["gobusgo://notice", "gobusgo://unavailable"]
    end

    test "lists nothing for a registry with no module" do
      registry = Registry.new(%{tools: [], resources: []})

      assert Registry.tool_definitions(registry) == []
      assert Registry.resource_definitions(registry) == []
    end

    test "refuses two tools with one name" do
      assert_raise Gobusgo.Assert.AssertionError, ~r/duplicate tool name/, fn ->
        Registry.new(%{tools: [EchoTool, EchoTool], resources: []})
      end
    end

    test "refuses a module that is not a tool" do
      assert_raise Gobusgo.Assert.AssertionError, ~r/must implement/, fn ->
        Registry.new(%{tools: [String], resources: []})
      end
    end
  end

  describe "fetch_tool/2 and fetch_resource/2" do
    setup do
      %{
        registry:
          Registry.new(%{tools: [EchoTool], resources: [NoticeResource, UnavailableResource]})
      }
    end

    test "return the module of a name the registry holds", %{registry: registry} do
      assert Registry.fetch_tool(registry, "echo") == {:ok, EchoTool}
      assert Registry.fetch_resource(registry, "gobusgo://notice") == {:ok, NoticeResource}
    end

    test "name an unknown tool and an unknown resource as such", %{registry: registry} do
      assert Registry.fetch_tool(registry, "nope") == :unknown
      assert Registry.fetch_resource(registry, "gobusgo://nope") == :unknown
    end
  end
end
