defmodule GobusgoWeb.Mcp.Resources.RoutingManifest do
  @moduledoc """
  The manifest of the routing snapshots, as the body of
  `GET /api/routing/manifest` writes it.
  """

  @behaviour GobusgoWeb.Mcp.Resource

  alias GobusgoWeb.Mcp.Answer
  alias GobusgoWeb.TransitQuery

  @impl GobusgoWeb.Mcp.Resource
  def definition do
    %{
      "uri" => "gobusgo://api/routing/manifest",
      "name" => "routing_manifest",
      "description" =>
        Answer.description("The snapshots of scheduled service that trip planning reads."),
      "mimeType" => "application/json"
    }
  end

  @impl GobusgoWeb.Mcp.Resource
  def read, do: {:ok, TransitQuery.routing_manifest()}
end
