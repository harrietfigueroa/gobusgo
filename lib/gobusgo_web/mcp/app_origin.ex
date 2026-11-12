defmodule GobusgoWeb.Mcp.AppOrigin do
  @moduledoc """
  The origin an MCP app's files are served from: `https` and the public host
  pages are served on where one is configured, and the endpoint's own
  address with none, as in development. The apps' `_meta.ui.csp` lists name
  it, and their documents load their bundle and stylesheet from it.
  """

  alias Gobusgo.Config
  alias GobusgoWeb.Endpoint

  @doc "The scheme and host the apps' files are served from."
  @spec origin() :: String.t()
  def origin do
    case Config.public_host() do
      {:ok, nil} -> Endpoint.url()
      {:ok, host} -> "https://" <> host
    end
  end
end
