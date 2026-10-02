defmodule GobusgoWeb.HealthControllerTest do
  # Sends requests through the endpoint with Phoenix.ConnTest, so the route,
  # the pipeline, and the controller are exercised together without a socket.
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint GobusgoWeb.Endpoint

  describe "GET /health" do
    test "answers 200 with the status as JSON" do
      conn = get(build_conn(), "/health")

      assert json_response(conn, 200) == %{"status" => "ok"}
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    end
  end
end
