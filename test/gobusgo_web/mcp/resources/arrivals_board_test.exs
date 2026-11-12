defmodule GobusgoWeb.Mcp.Resources.ArrivalsBoardTest do
  # Reads the app the way a host does, through `resources/read` on the
  # server's request handler, with the public host configured, and checks
  # what the host enforces and shows: the content type, the CSP lists, and
  # the document's references and credit. The public host is global
  # application state, hence the non-async case.
  use ExUnit.Case, async: false

  alias GobusgoWeb.Mcp.Registry
  alias GobusgoWeb.Mcp.Resources.ArrivalsBoard
  alias GobusgoWeb.Mcp.Server

  @legacy "2025-11-25"
  @registry Registry.new(%{tools: [], resources: [ArrivalsBoard]})
  @origin "https://gobusgo.example"

  setup do
    configured = Application.fetch_env!(:gobusgo, :public)
    Application.put_env(:gobusgo, :public, host: "gobusgo.example", required: false)
    on_exit(fn -> Application.put_env(:gobusgo, :public, configured) end)
    :ok
  end

  defp respond(method, params) do
    message = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    Server.respond(
      %{
        body: JSON.encode!(message),
        headers: %{protocol_version: @legacy, method: nil, name: nil}
      },
      @registry
    )
  end

  defp read_content do
    %{body: %{"result" => %{"contents" => [content]}}} =
      respond("resources/read", %{"uri" => ArrivalsBoard.uri()})

    content
  end

  test "is listed under a ui:// uri with the MCP Apps content type" do
    %{body: %{"result" => %{"resources" => [resource]}}} = respond("resources/list", %{})

    assert resource["uri"] == "ui://gobusgo/arrivals-board"
    assert resource["mimeType"] == "text/html;profile=mcp-app"
  end

  test "reads as an HTML document of the same content type" do
    content = read_content()

    assert content["mimeType"] == "text/html;profile=mcp-app"
    assert content["text"] =~ "<!doctype html>"
  end

  test "names the public host alone in the CSP lists" do
    %{"_meta" => %{"ui" => ui}} = read_content()

    assert ui["csp"] == %{"connectDomains" => [@origin], "resourceDomains" => [@origin]}
  end

  test "asks for a border and for no permission" do
    %{"_meta" => %{"ui" => ui}} = read_content()

    assert ui["prefersBorder"] == true
    refute Map.has_key?(ui, "permissions")
  end

  test "repeats the metadata on the listing" do
    %{body: %{"result" => %{"resources" => [resource]}}} = respond("resources/list", %{})

    assert resource["_meta"] == read_content()["_meta"]
  end

  test "loads one script and one stylesheet from the public host and no other file" do
    %{"text" => html} = read_content()

    assert [script] = Regex.scan(~r/<script[^>]*>/, html)
    assert [stylesheet] = Regex.scan(~r/<link[^>]*>/, html)
    assert hd(script) =~ ~s(src="#{@origin}/assets/js/arrivals_board.js")
    assert hd(stylesheet) =~ ~s(href="#{@origin}/assets/css/app.css")
  end

  test "carries no inline script" do
    %{"text" => html} = read_content()

    assert Regex.scan(~r/<script(?![^>]*\ssrc=)[^>]*>/, html) == []
  end

  test "holds the element the script fills" do
    %{"text" => html} = read_content()

    assert html =~ ~s(<main id="mcp-arrivals-board")
  end

  test "carries the transit data terms and names no agency in its title" do
    %{"text" => html} = read_content()

    assert html =~ "Transit Data Terms of Use"
    assert html =~ "<title>Arrivals board</title>"
    refute html =~ ~r/<title>[^<]*(Sound Transit|Metro)/
  end

  test "serves from the endpoint's own address where no public host is configured" do
    Application.put_env(:gobusgo, :public, host: nil, required: false)

    %{"_meta" => %{"ui" => %{"csp" => %{"connectDomains" => [origin]}}}} = read_content()

    assert origin == GobusgoWeb.Endpoint.url()
  end
end
