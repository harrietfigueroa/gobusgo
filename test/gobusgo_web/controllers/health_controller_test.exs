defmodule GobusgoWeb.HealthControllerTest do
  # Sends requests through the endpoint with Phoenix.ConnTest, so the route,
  # the pipeline, and the controller are exercised together without a socket.
  # The commit is application configuration, global state, hence the
  # non-async case.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint GobusgoWeb.Endpoint
  @revision "43402796c905c22db533043dee878950c74d5791"

  setup do
    configured = Application.get_env(:gobusgo, :revision)
    on_exit(fn -> Application.put_env(:gobusgo, :revision, configured) end)
  end

  describe "GET /health" do
    test "answers 200 with the status as JSON" do
      Application.put_env(:gobusgo, :revision, revision: nil)
      conn = get(build_conn(), "/health")

      assert json_response(conn, 200) == %{"status" => "ok"}
      assert get_resp_header(conn, "content-type") == ["application/json; charset=utf-8"]
    end

    test "answers the commit the application was built from beside the status" do
      Application.put_env(:gobusgo, :revision, revision: @revision)
      conn = get(build_conn(), "/health")

      assert json_response(conn, 200) == %{"status" => "ok", "revision" => @revision}
    end
  end
end
