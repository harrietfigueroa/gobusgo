defmodule GobusgoWeb.Mcp.TransitToolsEndpointTest do
  # Sends requests through the endpoint with Phoenix.ConnTest, the way an MCP
  # client does, to the registry the application is configured with, over
  # the application's global views, which the test fills with
  # Gobusgo.Test.TransitSeeds, hence the non-async case.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Gobusgo.Test.TransitSeeds
  alias GobusgoWeb.Mcp.StopHolds

  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @legacy "2025-11-25"
  @transit_tool_names ["arrivals", "find", "vehicles"]
  @transit_resource_uris ["gobusgo://api/agencies", "gobusgo://api/routing/manifest"]

  setup do
    TransitSeeds.restart_views()

    on_exit(fn ->
      Enum.each(StopHolds.held_stop_ids(), &StopHolds.release/1)
      TransitSeeds.restart_views()
    end)

    :ok = TransitSeeds.agencies([{"1", "Metro Transit"}])
    :ok = TransitSeeds.routes("1", [{"1_100", "8", "Seattle Center - Capitol Hill"}])
    :ok = TransitSeeds.stops("1_100", [{"1_1", "Capitol Hill Station", "300"}])
    :ok = TransitSeeds.vehicles("1", [{"1_a", "1_100"}])
  end

  defp rpc(method, params) do
    message = %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}

    conn =
      build_conn()
      |> put_req_header("accept", "application/json, text/event-stream")
      |> put_req_header("content-type", "application/json")
      |> put_req_header("mcp-protocol-version", @legacy)
      |> post("/mcp", JSON.encode!(message))

    assert conn.status == 200
    JSON.decode!(conn.resp_body)
  end

  defp call(name, arguments) do
    rpc("tools/call", %{"name" => name, "arguments" => arguments})
  end

  test "lists the three transit tools, each with an output schema" do
    assert %{"result" => %{"tools" => tools}} = rpc("tools/list", %{})

    transit_tools = for tool <- tools, tool["name"] in @transit_tool_names, do: tool
    assert Enum.map(transit_tools, & &1["name"]) == @transit_tool_names
    assert Enum.all?(transit_tools, &is_map(&1["outputSchema"]))
  end

  test "lists the two transit resources" do
    assert %{"result" => %{"resources" => resources}} = rpc("resources/list", %{})

    uris =
      for resource <- resources, resource["uri"] in @transit_resource_uris, do: resource["uri"]

    assert uris == @transit_resource_uris
  end

  test "reads the agencies resource" do
    assert %{"result" => %{"contents" => [%{"text" => text}]}} =
             rpc("resources/read", %{"uri" => "gobusgo://api/agencies"})

    assert %{"data" => [%{"id" => "1"}]} = JSON.decode!(text)
  end

  test "calls find" do
    assert %{"result" => %{"structuredContent" => %{"data" => %{"stops" => [%{"id" => "1_1"}]}}}} =
             call("find", %{"query" => "capitol"})
  end

  test "calls vehicles" do
    assert %{"result" => %{"structuredContent" => %{"data" => %{"vehicles" => [%{"id" => _id}]}}}} =
             call("vehicles", %{"agency" => ["1"]})
  end

  test "calls arrivals for a stop with no fetch" do
    assert %{"result" => %{"structuredContent" => %{"data" => %{"status" => "fetching"}}}} =
             call("arrivals", %{"stopId" => "1_1"})
  end

  test "answers invalid params for a call whose arguments do not match" do
    assert %{"error" => %{"code" => -32_602}} = call("arrivals", %{})
    assert %{"error" => %{"code" => -32_602}} = call("vehicles", %{"agency" => "1"})
  end

  test "answers a tool error as a result flagged isError" do
    too_many = for number <- 1..51, do: "agency-#{number}"

    assert %{"result" => %{"isError" => true}} = call("vehicles", %{"agency" => too_many})
  end
end
