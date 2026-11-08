defmodule GobusgoWeb.RoutingManifestControllerTest do
  # Sends requests through the endpoint with Phoenix.ConnTest and reads the
  # manifest of the application's snapshots process, which holds no snapshot
  # under test.
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint GobusgoWeb.Endpoint

  test "answers the manifest as JSON that every request revalidates" do
    conn = get(build_conn(), "/api/routing/manifest")

    assert json_response(conn, 200) == %{"formatVersion" => 2, "snapshots" => []}
    assert get_resp_header(conn, "cache-control") == ["no-cache"]
    assert [~s(") <> _tag] = get_resp_header(conn, "etag")
  end

  test "answers 304 with no body to a request that names the current tag" do
    [etag] = build_conn() |> get("/api/routing/manifest") |> get_resp_header("etag")

    conn = build_conn() |> put_req_header("if-none-match", etag) |> get("/api/routing/manifest")

    assert conn.status == 304
    assert conn.resp_body == ""
  end
end
