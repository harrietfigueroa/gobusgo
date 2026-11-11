defmodule Gobusgo.Test.McpFakes do
  @moduledoc """
  Tools and resources that implement the `GobusgoWeb.Mcp` contracts, for the
  tests of the endpoint, which ships with none of its own.
  """

  defmodule EchoTool do
    @moduledoc false
    @behaviour GobusgoWeb.Mcp.Tool

    @impl GobusgoWeb.Mcp.Tool
    def definition do
      %{
        "name" => "echo",
        "description" => "Returns its text.",
        "inputSchema" => %{
          "type" => "object",
          "properties" => %{"text" => %{"type" => "string"}},
          "required" => ["text"]
        }
      }
    end

    @impl GobusgoWeb.Mcp.Tool
    def arguments_schema, do: {:map, %{"text" => :string}}

    @impl GobusgoWeb.Mcp.Tool
    def call(%{"text" => text}) do
      {:ok, %{"content" => [%{"type" => "text", "text" => text}]}}
    end
  end

  defmodule RefusingTool do
    @moduledoc false
    @behaviour GobusgoWeb.Mcp.Tool

    @impl GobusgoWeb.Mcp.Tool
    def definition do
      %{
        "name" => "alpha_refuse",
        "description" => "Always reports a tool execution error.",
        "inputSchema" => %{"type" => "object", "additionalProperties" => false}
      }
    end

    @impl GobusgoWeb.Mcp.Tool
    def arguments_schema, do: {:map, %{}}

    @impl GobusgoWeb.Mcp.Tool
    def call(%{}), do: {:error, "The stop is not served today."}
  end

  defmodule NoticeResource do
    @moduledoc false
    @behaviour GobusgoWeb.Mcp.Resource

    @impl GobusgoWeb.Mcp.Resource
    def definition do
      %{
        "uri" => "gobusgo://notice",
        "name" => "notice",
        "description" => "A notice.",
        "mimeType" => "text/plain"
      }
    end

    @impl GobusgoWeb.Mcp.Resource
    def read, do: {:ok, "No service changes."}
  end

  defmodule UnavailableResource do
    @moduledoc false
    @behaviour GobusgoWeb.Mcp.Resource

    @impl GobusgoWeb.Mcp.Resource
    def definition do
      %{
        "uri" => "gobusgo://unavailable",
        "name" => "unavailable",
        "description" => "A resource whose source has no data yet.",
        "mimeType" => "application/json"
      }
    end

    @impl GobusgoWeb.Mcp.Resource
    def read, do: {:error, :unavailable}
  end
end
