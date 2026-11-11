defmodule GobusgoWeb.Mcp.Resources.Agencies do
  @moduledoc """
  The agencies of the current fetch of the agency view, as the body of
  `GET /api/agencies` writes them.
  """

  @behaviour GobusgoWeb.Mcp.Resource

  alias Gobusgo.OneBusAway.AgencyView
  alias GobusgoWeb.AgencyJSON
  alias GobusgoWeb.Mcp.Answer

  @impl GobusgoWeb.Mcp.Resource
  def definition do
    %{
      "uri" => "gobusgo://api/agencies",
      "name" => "agencies",
      "description" =>
        Answer.description(
          "Every transit agency with coverage, with its identifier and its area."
        ),
      "mimeType" => "application/json"
    }
  end

  @impl GobusgoWeb.Mcp.Resource
  def read do
    case AgencyView.current(AgencyView) do
      nil -> {:error, :unavailable}
      fetch -> {:ok, JSON.encode!(AgencyJSON.index(fetch))}
    end
  end
end
