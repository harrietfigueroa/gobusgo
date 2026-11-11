defmodule GobusgoWeb.IntersectionManifestControllerTest do
  # Sends requests through the endpoint with Phoenix.ConnTest and reads the
  # manifest the local file writer stored in the test's temporary directory,
  # which the test names as the base directory of the reader.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @manifest %{
    "builtAt" => "2026-11-10T22:00:00Z",
    "index" => %{"path" => "/intersections/intersections-index-aa.bin.gz"},
    "shards" => []
  }

  setup %{tmp_dir: tmp_dir} do
    configured = Application.get_env(:gobusgo, Gobusgo.Reader.LocalFile)
    Application.put_env(:gobusgo, Gobusgo.Reader.LocalFile, base_dir: tmp_dir)
    on_exit(fn -> Application.put_env(:gobusgo, Gobusgo.Reader.LocalFile, configured) end)
    :ok
  end

  defp store(tmp_dir, content) do
    path = Path.join(tmp_dir, "intersections/manifest.json")
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  test "answers 503 problem details with Retry-After while there is no build" do
    conn = get(build_conn(), "/api/intersections/manifest")

    assert json_response(conn, 503)["status"] == 503
    assert get_resp_header(conn, "retry-after") == ["60"]
    assert get_resp_header(conn, "content-type") == ["application/problem+json; charset=utf-8"]
  end

  test "answers the manifest as JSON that every request revalidates", %{tmp_dir: tmp_dir} do
    store(tmp_dir, JSON.encode!(@manifest))
    conn = get(build_conn(), "/api/intersections/manifest")

    assert json_response(conn, 200) == @manifest
    assert get_resp_header(conn, "cache-control") == ["no-cache"]
    assert [~s(") <> _tag] = get_resp_header(conn, "etag")
  end

  test "the tag is the SHA-256 of the body", %{tmp_dir: tmp_dir} do
    store(tmp_dir, JSON.encode!(@manifest))
    conn = get(build_conn(), "/api/intersections/manifest")

    expected =
      ~s(") <> Base.encode16(:crypto.hash(:sha256, conn.resp_body), case: :lower) <> ~s(")

    assert get_resp_header(conn, "etag") == [expected]
  end

  test "answers 304 with no body to a request that holds the manifest", %{tmp_dir: tmp_dir} do
    store(tmp_dir, JSON.encode!(@manifest))
    [etag] = build_conn() |> get("/api/intersections/manifest") |> get_resp_header("etag")

    conn =
      build_conn() |> put_req_header("if-none-match", etag) |> get("/api/intersections/manifest")

    assert response(conn, 304) == ""
  end

  test "answers 200 to a request that holds another manifest", %{tmp_dir: tmp_dir} do
    store(tmp_dir, JSON.encode!(@manifest))

    conn =
      build_conn()
      |> put_req_header("if-none-match", ~s("0"))
      |> get("/api/intersections/manifest")

    assert conn.status == 200
  end

  test "answers 503 for content that is not the manifest a build writes", %{tmp_dir: tmp_dir} do
    for content <- ["not json", "[]", ~s({"builtAt": 1})] do
      store(tmp_dir, content)
      conn = get(build_conn(), "/api/intersections/manifest")
      assert json_response(conn, 503)["status"] == 503
    end
  end
end
