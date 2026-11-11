defmodule GobusgoWeb.PublicCorsTest do
  # Sends requests through the endpoint with Phoenix.ConnTest and reads the
  # CORS header of the answer, whatever its status, for the three manifests
  # an MCP App fetches from another origin and for routes that stay
  # same-origin. The intersection manifest is read through the reader, which
  # the test points at an empty directory, so that route answers 503 here.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @manifest_paths [
    "/api/routing/manifest",
    "/api/addresses/manifest",
    "/api/intersections/manifest"
  ]

  setup %{tmp_dir: tmp_dir} do
    configured = Application.get_env(:gobusgo, Gobusgo.Reader.LocalFile)
    Application.put_env(:gobusgo, Gobusgo.Reader.LocalFile, base_dir: tmp_dir)
    on_exit(fn -> Application.put_env(:gobusgo, Gobusgo.Reader.LocalFile, configured) end)
    :ok
  end

  for path <- @manifest_paths do
    test "answers a GET of #{path} with the wildcard origin" do
      conn = get(build_conn(), unquote(path))

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end

    test "answers a HEAD of #{path} with the wildcard origin" do
      conn = head(build_conn(), unquote(path))

      assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
    end
  end

  test "keeps the wildcard origin on a 304 answer" do
    [etag] = build_conn() |> get("/api/routing/manifest") |> get_resp_header("etag")

    conn = build_conn() |> put_req_header("if-none-match", etag) |> get("/api/routing/manifest")

    assert conn.status == 304
    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "sets no CORS header on a route whose answer stays same-origin" do
    conn = get(build_conn(), "/api/agencies")

    assert get_resp_header(conn, "access-control-allow-origin") == []
  end

  test "sets no CORS header on a method the manifest route does not serve" do
    conn = post(build_conn(), "/api/routing/manifest", %{})

    assert get_resp_header(conn, "access-control-allow-origin") == []
  end
end
