defmodule GobusgoWeb.McpControllerTest do
  # Sends requests through the endpoint with Phoenix.ConnTest, the way an MCP
  # client does, and reads the usage the requests leave back through the
  # reader. A recorder runs under the name the controller records with,
  # writing under the test's temporary directory; the name is global, hence
  # the non-async case. Under test the application starts no recorder, and
  # each test starts from a registry that holds no tool, since the
  # application's own tools are tested in their own files.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Plug.Conn

  alias Gobusgo.Reader
  alias Gobusgo.Test.McpFakes.EchoTool
  alias Gobusgo.Test.McpFakes.NoticeResource
  alias Gobusgo.Usage

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @legacy "2025-11-25"
  @modern "2026-07-28"
  @prefix "usage/page-connections/"
  @json_content_type "application/json; charset=utf-8"
  @request_bytes_max 1_048_576

  setup do
    configured = Application.fetch_env!(:gobusgo, GobusgoWeb.Mcp)
    Application.put_env(:gobusgo, GobusgoWeb.Mcp, tools: [], resources: [])
    on_exit(fn -> Application.put_env(:gobusgo, GobusgoWeb.Mcp, configured) end)
    :ok
  end

  defp start_recorder(%{tmp_dir: tmp_dir}) do
    start_supervised!({Usage, name: Usage, write_options: [base_dir: tmp_dir]})
    :ok
  end

  defp post_json(message, headers \\ []) do
    conn =
      Enum.reduce(headers, build_conn(), fn {name, value}, conn ->
        put_req_header(conn, name, value)
      end)

    conn
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("content-type", "application/json")
    |> post("/mcp", JSON.encode!(message))
  end

  defp rpc(method, params, id \\ 1) do
    %{"jsonrpc" => "2.0", "id" => id, "method" => method, "params" => params}
  end

  defp modern_params(params) do
    meta = %{
      "io.modelcontextprotocol/protocolVersion" => @modern,
      "io.modelcontextprotocol/clientInfo" => %{"name" => "TestClient", "version" => "1"},
      "io.modelcontextprotocol/clientCapabilities" => %{}
    }

    Map.put(params, "_meta", meta)
  end

  defp records(%{tmp_dir: tmp_dir}) do
    {:ok, _record_count} = Usage.write(Usage)

    {:ok, %{destinations: destinations}} =
      Reader.discover(%{prefix: @prefix, limit: 100, order: :ascending, cursor: nil},
        base_dir: tmp_dir
      )

    Enum.flat_map(destinations, fn destination ->
      {:ok, content} = Reader.read(destination, base_dir: tmp_dir)
      JSON.decode!(content)["records"]
    end)
  end

  describe "a client of the 2025-11-25 revision" do
    test "initializes, acknowledges, and lists an empty tool list, with no session id" do
      initialize =
        rpc("initialize", %{
          "protocolVersion" => @legacy,
          "capabilities" => %{},
          "clientInfo" => %{"name" => "TestClient", "version" => "1"}
        })

      conn = post_json(initialize)

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == [@json_content_type]
      assert get_resp_header(conn, "mcp-session-id") == []

      assert %{"id" => 1, "result" => %{"protocolVersion" => @legacy}} =
               JSON.decode!(conn.resp_body)

      conn =
        post_json(
          %{"jsonrpc" => "2.0", "method" => "notifications/initialized"},
          [{"mcp-protocol-version", @legacy}]
        )

      assert conn.status == 202
      assert conn.resp_body == ""

      conn = post_json(rpc("tools/list", %{}, 2), [{"mcp-protocol-version", @legacy}])

      assert conn.status == 200
      assert JSON.decode!(conn.resp_body)["result"] == %{"tools" => []}
    end
  end

  describe "a client of the 2026-07-28 revision" do
    test "lists the tools with no initialize before it" do
      conn =
        post_json(rpc("tools/list", modern_params(%{})), [
          {"mcp-protocol-version", @modern},
          {"mcp-method", "tools/list"}
        ])

      assert conn.status == 200

      assert %{"result" => %{"tools" => [], "resultType" => "complete"}} =
               JSON.decode!(conn.resp_body)
    end

    test "gets a JSON-RPC error body, not problem details, for a request without its headers" do
      conn = post_json(rpc("tools/list", modern_params(%{})), [{"mcp-protocol-version", @modern}])

      assert conn.status == 400
      assert get_resp_header(conn, "content-type") == [@json_content_type]
      assert %{"error" => %{"code" => -32_020}} = JSON.decode!(conn.resp_body)
    end
  end

  describe "a request that goes wrong" do
    test "a malformed body gets the parse error" do
      conn =
        build_conn()
        |> put_req_header("accept", "application/json, text/event-stream")
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", "{not json")

      assert conn.status == 400
      assert get_resp_header(conn, "content-type") == [@json_content_type]

      assert JSON.decode!(conn.resp_body) ==
               %{
                 "jsonrpc" => "2.0",
                 "id" => nil,
                 "error" => %{"code" => -32_700, "message" => "Parse error"}
               }
    end

    test "an unknown method gets method not found" do
      conn = post_json(rpc("tools/unheard-of", %{}))

      assert %{"id" => 1, "error" => %{"code" => -32_601}} = JSON.decode!(conn.resp_body)
    end

    test "an unknown tool gets invalid params naming it" do
      conn = post_json(rpc("tools/call", %{"name" => "nope", "arguments" => %{}}))

      assert %{"error" => %{"code" => -32_602, "message" => "Unknown tool: nope"}} =
               JSON.decode!(conn.resp_body)
    end

    test "a body past the size bound gets 413 and an invalid request" do
      body = JSON.encode!(rpc("ping", %{"padding" => String.duplicate("a", @request_bytes_max)}))

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("content-type", "application/json")
        |> post("/mcp", body)

      assert conn.status == 413
      assert %{"error" => %{"code" => -32_600}} = JSON.decode!(conn.resp_body)
    end
  end

  describe "a method other than POST" do
    for method <- ["GET", "DELETE", "PUT"] do
      test "#{method} is answered with 405 and the methods the endpoint allows" do
        conn =
          build_conn()
          |> put_req_header("accept", "text/event-stream, application/json")
          |> dispatch(@endpoint, unquote(method), "/mcp")

        assert conn.status == 405
        assert get_resp_header(conn, "allow") == ["POST"]
      end
    end
  end

  describe "the Origin header with a public host" do
    setup do
      configured = Application.fetch_env!(:gobusgo, :public)
      Application.put_env(:gobusgo, :public, host: "gobusgo.example", required: false)
      on_exit(fn -> Application.put_env(:gobusgo, :public, configured) end)
      :ok
    end

    test "is not required: a request with none proceeds" do
      assert post_json(rpc("ping", %{})).status == 200
    end

    test "proceeds when it names the public host" do
      conn = post_json(rpc("ping", %{}), [{"origin", "https://gobusgo.example"}])

      assert conn.status == 200
    end

    for origin <- ["https://evil.example", "null"] do
      test "refuses #{origin} with 403 and a JSON-RPC error" do
        conn = post_json(rpc("ping", %{}), [{"origin", unquote(origin)}])

        assert conn.status == 403
        assert get_resp_header(conn, "content-type") == [@json_content_type]

        assert %{"jsonrpc" => "2.0", "id" => nil, "error" => %{"code" => -32_600}} =
                 JSON.decode!(conn.resp_body)
      end
    end

    test "refuses a GET from another origin too" do
      conn = build_conn() |> put_req_header("origin", "https://evil.example") |> get("/mcp")

      assert conn.status == 403
    end
  end

  describe "the Origin header with no public host" do
    test "lets any origin proceed, as the socket does" do
      conn = post_json(rpc("ping", %{}), [{"origin", "https://anywhere.example"}])

      assert conn.status == 200
    end
  end

  describe "usage of a request refused for its origin" do
    setup [:start_recorder]

    setup do
      configured = Application.fetch_env!(:gobusgo, :public)
      Application.put_env(:gobusgo, :public, host: "gobusgo.example", required: false)
      on_exit(fn -> Application.put_env(:gobusgo, :public, configured) end)
      :ok
    end

    test "is counted like any request", context do
      post_json(rpc("ping", %{}), [{"origin", "https://evil.example"}])

      assert [%{"page" => "mcp"}] = records(context)
    end
  end

  describe "a registry that holds a tool and a resource" do
    setup do
      configured = Application.fetch_env!(:gobusgo, GobusgoWeb.Mcp)

      Application.put_env(:gobusgo, GobusgoWeb.Mcp,
        tools: [EchoTool],
        resources: [NoticeResource]
      )

      on_exit(fn -> Application.put_env(:gobusgo, GobusgoWeb.Mcp, configured) end)
      :ok
    end

    test "lists the tool and calls it" do
      conn = post_json(rpc("tools/list", %{}))
      assert %{"result" => %{"tools" => [%{"name" => "echo"}]}} = JSON.decode!(conn.resp_body)

      conn = post_json(rpc("tools/call", %{"name" => "echo", "arguments" => %{"text" => "hi"}}))

      assert %{"result" => %{"content" => [%{"text" => "hi"}]}} = JSON.decode!(conn.resp_body)
    end

    test "lists the resource and reads it" do
      conn = post_json(rpc("resources/list", %{}))

      assert %{"result" => %{"resources" => [%{"uri" => "gobusgo://notice"}]}} =
               JSON.decode!(conn.resp_body)

      conn = post_json(rpc("resources/read", %{"uri" => "gobusgo://notice"}))

      assert %{"result" => %{"contents" => [%{"text" => "No service changes."}]}} =
               JSON.decode!(conn.resp_body)
    end
  end

  describe "usage" do
    setup :start_recorder

    test "counts each request as a record of the page mcp", context do
      post_json(rpc("tools/list", %{}, 1))
      post_json(rpc("tools/list", %{}, 2))
      post_json(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})

      assert [%{"page" => "mcp"}, %{"page" => "mcp"}, %{"page" => "mcp"}] = records(context)
    end

    test "counts a malformed request and a refused method too", context do
      build_conn()
      |> put_req_header("accept", "application/json")
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", "{not json")

      get(build_conn(), "/mcp")

      assert [%{"page" => "mcp"}, %{"page" => "mcp"}] = records(context)
    end

    test "records the facts of a page connection the request has, and no identifier", context do
      post_json(rpc("tools/list", %{}), [{"user-agent", "claude-code/2.0 (cli)"}])

      assert [record] = records(context)
      assert record["deviceClass"] == "unknown"
      assert record["durationMs"] == 0
      assert record["filter"] == %{}
      assert record["reconnect"] == nil
      assert record |> Map.keys() |> Enum.sort() == Usage.Records.fields()
      refute JSON.encode!(record) =~ "claude-code"
    end
  end

  describe "with no recorder running" do
    test "answers the request and records nothing" do
      conn = post_json(rpc("ping", %{}))

      assert conn.status == 200
    end
  end
end
