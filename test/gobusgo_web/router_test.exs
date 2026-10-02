defmodule GobusgoWeb.RouterTest do
  # Sends requests no route serves through the endpoint with Phoenix.ConnTest
  # and checks the problem details the client receives: the status, the media
  # type, and the body.
  use ExUnit.Case, async: true

  import Phoenix.ConnTest
  import Plug.Conn

  @endpoint GobusgoWeb.Endpoint
  @problem_content_type "application/problem+json; charset=utf-8"

  describe "an unknown route" do
    test "answers 404 with problem details" do
      conn = get(build_conn(), "/nope")

      assert conn.status == 404
      assert get_resp_header(conn, "content-type") == [@problem_content_type]

      assert JSON.decode!(conn.resp_body) == %{
               "type" => "about:blank",
               "title" => "Not Found",
               "status" => 404,
               "detail" => "No route matches GET /nope."
             }
    end

    test "answers 404 for a known path under another method" do
      conn = post(build_conn(), "/health")

      assert conn.status == 404
      assert JSON.decode!(conn.resp_body)["detail"] == "No route matches POST /health."
    end
  end

  describe "a request for a media type the route does not serve" do
    test "answers 406 with problem details when it accepts neither JSON nor HTML" do
      {status, headers, body} =
        assert_error_sent 406, fn ->
          build_conn() |> put_req_header("accept", "application/xml") |> get("/health")
        end

      assert status == 406
      assert {"content-type", @problem_content_type} in headers

      assert JSON.decode!(body) == %{
               "type" => "about:blank",
               "title" => "Not Acceptable",
               "status" => 406
             }
    end

    test "answers 406 with an HTML page when it accepts only HTML" do
      {status, headers, body} =
        assert_error_sent 406, fn ->
          build_conn() |> put_req_header("accept", "text/html") |> get("/health")
        end

      assert status == 406
      assert {"content-type", "text/html; charset=utf-8"} in headers
      assert body =~ "<h1>406 Not Acceptable</h1>"
    end
  end

  describe "an unknown route requested by a browser" do
    test "answers 404 with an HTML page" do
      conn = build_conn() |> put_req_header("accept", "text/html") |> get("/nope")

      assert conn.status == 404
      assert get_resp_header(conn, "content-type") == ["text/html; charset=utf-8"]
      assert conn.resp_body =~ "<h1>404 Not Found</h1>"
    end
  end

  describe "an unknown API route" do
    for accept <- ["text/html,application/xhtml+xml,*/*;q=0.8", "application/json"] do
      test "answers 404 with problem details for a request that accepts #{accept}" do
        conn = build_conn() |> put_req_header("accept", unquote(accept)) |> get("/api/nope")

        assert conn.status == 404
        assert get_resp_header(conn, "content-type") == [@problem_content_type]

        assert JSON.decode!(conn.resp_body) == %{
                 "type" => "about:blank",
                 "title" => "Not Found",
                 "status" => 404,
                 "detail" => "No route matches GET /api/nope."
               }
      end
    end
  end
end
