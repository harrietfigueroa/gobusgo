defmodule GobusgoWeb.Mcp.ResourcesTest do
  # Reads the two resources the way the endpoint does and compares them with
  # the bodies the controllers answer, over the application's global agency
  # view and routing snapshots, hence the non-async case.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  @moduletag capture_log: true

  alias Gobusgo.Test.TransitSeeds
  alias GobusgoWeb.Mcp.Resources.Agencies
  alias GobusgoWeb.Mcp.Resources.RoutingManifest

  @endpoint GobusgoWeb.Endpoint

  setup do
    TransitSeeds.restart_views()
    on_exit(&TransitSeeds.restart_views/0)
  end

  describe "agencies" do
    test "reads the body GET /api/agencies answers" do
      :ok = TransitSeeds.agencies([{"40", "Sound Transit"}, {"1", "Metro Transit"}])

      assert {:ok, text} = Agencies.read()

      conn = get(build_conn(), "/api/agencies")
      assert JSON.decode!(text) == JSON.decode!(conn.resp_body)
    end

    test "is unavailable before the agency view has a fetch" do
      assert Agencies.read() == {:error, :unavailable}
    end

    test "is listed at the uri of the route it answers for, as JSON" do
      assert %{"uri" => "gobusgo://api/agencies", "mimeType" => "application/json"} =
               Agencies.definition()
    end
  end

  describe "routing manifest" do
    test "reads the body GET /api/routing/manifest answers" do
      assert {:ok, text} = RoutingManifest.read()

      conn = get(build_conn(), "/api/routing/manifest")
      assert text == conn.resp_body
    end

    test "is listed at the uri of the route it answers for, as JSON" do
      assert %{"uri" => "gobusgo://api/routing/manifest", "mimeType" => "application/json"} =
               RoutingManifest.definition()
    end
  end

  test "each resource's description names the terms and credits the data as provided as is" do
    for resource <- [Agencies, RoutingManifest] do
      %{"description" => description} = resource.definition()

      assert description =~ "https://www.soundtransit.org"
      assert description =~ ~s(as is)
    end
  end
end
