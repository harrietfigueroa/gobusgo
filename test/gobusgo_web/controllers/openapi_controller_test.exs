defmodule GobusgoWeb.OpenApiControllerTest do
  # Sends requests through the endpoint with Phoenix.ConnTest and compares
  # the answer with the document read from disk, decoded by the built-in JSON
  # module.
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint GobusgoWeb.Endpoint
  @document_path Path.expand("../../../priv/openapi.json", __DIR__)

  test "answers the public document as JSON" do
    conn = get(build_conn(), "/api/openapi.json")

    assert json_response(conn, 200) == @document_path |> File.read!() |> JSON.decode!()
  end

  test "answers the exact bytes of the file" do
    conn = get(build_conn(), "/api/openapi.json")

    assert conn.resp_body == File.read!(@document_path)
  end

  test "answers with a content type of application/json" do
    conn = get(build_conn(), "/api/openapi.json")

    assert [content_type] = get_resp_header(conn, "content-type")
    assert String.starts_with?(content_type, "application/json")
  end

  test "answers a request that every use revalidates" do
    conn = get(build_conn(), "/api/openapi.json")

    assert get_resp_header(conn, "cache-control") == ["no-cache"]
  end

  test "tags the body with the SHA-256 of the file as a strong etag" do
    conn = get(build_conn(), "/api/openapi.json")

    digest = Base.encode16(:crypto.hash(:sha256, File.read!(@document_path)), case: :lower)
    assert get_resp_header(conn, "etag") == [~s(") <> digest <> ~s(")]
  end

  test "allows a page of any origin to read it" do
    conn = get(build_conn(), "/api/openapi.json")

    assert get_resp_header(conn, "access-control-allow-origin") == ["*"]
  end

  test "answers 304 with no body to a request that names the current tag" do
    [etag] = build_conn() |> get("/api/openapi.json") |> get_resp_header("etag")

    conn = build_conn() |> put_req_header("if-none-match", etag) |> get("/api/openapi.json")

    assert conn.status == 304
    assert conn.resp_body == ""
  end

  test "answers 200 to a request that names another tag" do
    conn =
      build_conn() |> put_req_header("if-none-match", ~s("other")) |> get("/api/openapi.json")

    assert conn.status == 200
  end

  test "answers HEAD with the headers of GET and no body" do
    get_conn = get(build_conn(), "/api/openapi.json")
    head_conn = head(build_conn(), "/api/openapi.json")

    assert head_conn.status == 200
    assert head_conn.resp_body == ""
    assert get_resp_header(head_conn, "etag") == get_resp_header(get_conn, "etag")
    assert get_resp_header(head_conn, "access-control-allow-origin") == ["*"]
  end

  test "answers a request that accepts application/openapi+json" do
    conn =
      build_conn()
      |> put_req_header("accept", "application/openapi+json")
      |> get("/api/openapi.json")

    assert conn.status == 200
    assert conn.resp_body == File.read!(@document_path)
  end

  test "leaves the private document to the fallback 404" do
    conn = get(build_conn(), "/api/openapi.private.json")

    assert conn.status == 404
  end
end
