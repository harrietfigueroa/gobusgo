defmodule GobusgoWeb.Mcp.Resources.TripApp do
  @moduledoc """
  The `ui://` resource the `plan_trip` tool links: the trip planner app, an
  HTML document of the MCP Apps content type that loads one bundle and one
  stylesheet from the public host.

  Its `_meta.ui.csp` names that one origin under `connectDomains`, which the
  app fetches the routing, places, address, and intersection files from, and
  under `resourceDomains`, which the bundle and the stylesheet load from.
  The origin is `https` and the host pages are served on where one is
  configured, and the endpoint's own address with none, as in development.
  The geolocation permission is requested so the app can offer the rider's
  position as a start; a host that withholds it leaves that offer out.
  """

  @behaviour GobusgoWeb.Mcp.Resource

  import GobusgoWeb.Mcp.AppOrigin, only: [origin: 0]

  alias GobusgoWeb.Endpoint
  alias GobusgoWeb.Mcp.TripAppDocument

  @uri "ui://gobusgo/plan-trip"
  # https://github.com/modelcontextprotocol/ext-apps/blob/main/specification/2026-01-26/apps.mdx — checked 2026-11-11
  @mime_type "text/html;profile=mcp-app"
  @script_path "/assets/js/trip_app.js"
  @stylesheet_path "/assets/css/app.css"

  @doc "The address of the resource."
  @spec uri() :: String.t()
  def uri, do: @uri

  @impl GobusgoWeb.Mcp.Resource
  def definition do
    %{
      "uri" => @uri,
      "name" => "trip_planner",
      "description" =>
        "Finds the places of a trip and shows its journeys for the rider to choose.",
      "mimeType" => @mime_type,
      "_meta" => meta(origin())
    }
  end

  @impl GobusgoWeb.Mcp.Resource
  def read do
    {:ok,
     TripAppDocument.render(%{
       origin: origin(),
       script_path: Endpoint.static_path(@script_path),
       stylesheet_path: Endpoint.static_path(@stylesheet_path)
     })}
  end

  # The CSP lists and the permissions sit in `_meta.ui`, and the host reads
  # them from the `resources/read` contents.
  # https://github.com/modelcontextprotocol/ext-apps/blob/main/docs/csp-cors.md — checked 2026-11-11
  defp meta(origin) do
    %{
      "ui" => %{
        "csp" => %{"connectDomains" => [origin], "resourceDomains" => [origin]},
        "permissions" => %{"geolocation" => %{}},
        "prefersBorder" => true
      }
    }
  end
end
