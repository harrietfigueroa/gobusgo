defmodule GobusgoWeb.Mcp.ServerInfo do
  @moduledoc """
  What the MCP server says of itself: its name and version, its
  capabilities, and the instructions every client reads. Everything here is
  pure.

  The name carries no agency's name, which the data terms forbid. The
  instructions credit the transit data and link the terms with the wording
  and the address of `GobusgoWeb.AppInfo`, the ones the info panel shows,
  and ask the client to pass the terms on to whoever it gives the data to.
  """

  alias GobusgoWeb.AppInfo

  @name "gobusgo"
  @version Mix.Project.config()[:version]

  # Both capabilities are declared whatever the registry holds, with no
  # `listChanged` and no `subscribe`, the features that need a notification
  # from the server to the client.
  # https://modelcontextprotocol.io/specification/2025-11-25/server/tools#capabilities — checked 2026-11-11
  @capabilities %{"tools" => %{}, "resources" => %{}}

  @pass_on "Provide these terms to anyone you give the data to."

  @doc "The name and the version of the server."
  @spec implementation() :: %{String.t() => String.t()}
  def implementation, do: %{"name" => @name, "version" => @version}

  @doc "The capabilities the server declares."
  @spec capabilities() :: %{String.t() => map()}
  def capabilities, do: @capabilities

  @doc "The instructions a client reads on connecting."
  @spec instructions() :: String.t()
  def instructions do
    %{lead: lead, trail: trail} = AppInfo.provision()
    %{name: terms_name, url: terms_url} = AppInfo.terms()

    credit =
      lead <>
        AppInfo.agencies_credit([]) <>
        ", under the #{terms_name} (#{terms_url}) " <> trail

    Enum.join(
      ["Gobusgo serves transit data for the Puget Sound region.", credit, @pass_on],
      " "
    )
  end
end
