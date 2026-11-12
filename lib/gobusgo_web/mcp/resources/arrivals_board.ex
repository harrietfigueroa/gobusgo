defmodule GobusgoWeb.Mcp.Resources.ArrivalsBoard do
  @moduledoc """
  The `ui://` resource the `arrivals_board` tool links: the arrivals board
  app, an HTML document of the MCP Apps content type that loads one bundle
  and one stylesheet from the public host.

  Its `_meta.ui.csp` names that one origin under `connectDomains` and under
  `resourceDomains`, the origin `GobusgoWeb.Mcp.AppOrigin` gives. The app
  requests no permission. The resource is the same whatever stop the tool is
  called for: the app reads its stop from the tool's result.
  """

  @behaviour GobusgoWeb.Mcp.Resource

  import GobusgoWeb.Mcp.AppOrigin, only: [origin: 0]

  alias GobusgoWeb.Endpoint
  alias GobusgoWeb.Mcp.ArrivalsBoardDocument

  @uri "ui://gobusgo/arrivals-board"
  # https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx — checked 2026-11-11
  @mime_type "text/html;profile=mcp-app"
  @script_path "/assets/js/arrivals_board.js"
  @stylesheet_path "/assets/css/app.css"

  @doc "The address of the resource."
  @spec uri() :: String.t()
  def uri, do: @uri

  @impl GobusgoWeb.Mcp.Resource
  def definition do
    %{
      "uri" => @uri,
      "name" => "arrivals_board",
      "description" =>
        "Shows a stop's next arrivals and keeps them current while the rider watches.",
      "mimeType" => @mime_type,
      "_meta" => meta(origin())
    }
  end

  @impl GobusgoWeb.Mcp.Resource
  def read do
    {:ok,
     ArrivalsBoardDocument.render(%{
       origin: origin(),
       script_path: Endpoint.static_path(@script_path),
       stylesheet_path: Endpoint.static_path(@stylesheet_path)
     })}
  end

  # The CSP lists sit in `_meta.ui`, and the host reads them from the
  # `resources/read` contents.
  # https://github.com/modelcontextprotocol/ext-apps/blob/main/docs/csp-cors.md — checked 2026-11-11
  defp meta(origin) do
    %{
      "ui" => %{
        "csp" => %{"connectDomains" => [origin], "resourceDomains" => [origin]},
        "prefersBorder" => true
      }
    }
  end
end
