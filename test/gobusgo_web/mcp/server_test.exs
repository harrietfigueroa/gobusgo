defmodule GobusgoWeb.Mcp.ServerTest do
  # Hands the server what the controller reads off a request, a body and
  # the three MCP headers, with registries built from the fake tools of the
  # test support, and checks the status and the body it decides on. The
  # server is pure, so no connection and no process takes part.
  use ExUnit.Case, async: true

  alias Gobusgo.Test.McpFakes.EchoTool
  alias Gobusgo.Test.McpFakes.NoticeResource
  alias Gobusgo.Test.McpFakes.RefusingTool
  alias Gobusgo.Test.McpFakes.UnavailableResource
  alias GobusgoWeb.AppInfo
  alias GobusgoWeb.Mcp.Registry
  alias GobusgoWeb.Mcp.Server

  @legacy "2025-11-25"
  @modern "2026-07-28"
  @empty Registry.new(%{tools: [], resources: []})
  @full Registry.new(%{
          tools: [EchoTool, RefusingTool],
          resources: [NoticeResource, UnavailableResource]
        })
  @no_headers %{protocol_version: nil, method: nil, name: nil}
  @initialize_params %{
    "protocolVersion" => @legacy,
    "capabilities" => %{},
    "clientInfo" => %{"name" => "TestClient", "version" => "1"}
  }

  defp request(method, params \\ nil, id \\ 1) do
    message = %{"jsonrpc" => "2.0", "id" => id, "method" => method}

    case params do
      nil -> message
      params -> Map.put(message, "params", params)
    end
  end

  defp legacy_headers, do: %{@no_headers | protocol_version: @legacy}

  defp modern_meta(overrides \\ %{}) do
    Map.merge(
      %{
        "io.modelcontextprotocol/protocolVersion" => @modern,
        "io.modelcontextprotocol/clientInfo" => %{"name" => "TestClient", "version" => "1"},
        "io.modelcontextprotocol/clientCapabilities" => %{}
      },
      overrides
    )
  end

  # A request of the 2026-07-28 revision with the headers a client mirrors
  # out of it: the method, and the name or uri of the target where the
  # revision names one.
  defp modern(method, params \\ %{}) do
    message = request(method, Map.put(params, "_meta", modern_meta()))

    name =
      case params do
        %{"name" => name} -> name
        %{"uri" => uri} -> uri
        %{} -> nil
      end

    {message, %{protocol_version: @modern, method: method, name: name}}
  end

  defp respond({message, headers}, registry) do
    Server.respond(%{body: JSON.encode!(message), headers: headers}, registry)
  end

  defp respond_legacy(message, registry \\ @empty) do
    respond({message, legacy_headers()}, registry)
  end

  defp error_code(%{body: %{"error" => %{"code" => code}}}), do: code

  describe "initialize" do
    test "answers the revision the client asks for, with the server's capabilities" do
      response = respond_legacy(request("initialize", @initialize_params, 7))

      assert %{status: 200, body: %{"jsonrpc" => "2.0", "id" => 7, "result" => result}} =
               response

      assert result["protocolVersion"] == @legacy
      assert result["capabilities"] == %{"tools" => %{}, "resources" => %{}}
      assert %{"name" => "gobusgo", "version" => _version} = result["serverInfo"]
      refute Map.has_key?(result, "resultType")
    end

    test "answers the newest revision that handshakes to a client asking for another" do
      params = %{@initialize_params | "protocolVersion" => "2024-11-05"}

      response = respond_legacy(request("initialize", params))

      assert response.body["result"]["protocolVersion"] == @legacy
    end

    test "carries the terms of use and the as-is credit in its instructions" do
      %{body: %{"result" => %{"instructions" => instructions}}} =
        respond_legacy(request("initialize", @initialize_params))

      assert instructions =~ AppInfo.terms().url
      assert instructions =~ ~s("as is")
    end

    test "answers invalid params for a request with no protocol version" do
      response = respond_legacy(request("initialize", %{"capabilities" => %{}}))

      assert response.status == 200
      assert error_code(response) == -32_602
    end

    test "is an unknown method to a request that names the 2026-07-28 revision" do
      response = respond(modern("initialize"), @empty)

      assert response.status == 404
      assert error_code(response) == -32_601
    end
  end

  describe "notifications" do
    test "notifications/initialized is accepted with no body" do
      message = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}

      assert respond({message, legacy_headers()}, @empty) == %{status: 202, body: nil}
    end

    test "a notification of a method the server does not know is accepted with no body" do
      message = %{"jsonrpc" => "2.0", "method" => "notifications/unheard-of"}

      assert respond({message, legacy_headers()}, @empty) == %{status: 202, body: nil}
    end
  end

  describe "ping" do
    test "answers an empty result to a client of an earlier revision" do
      assert respond_legacy(request("ping", nil, "abc")) ==
               %{status: 200, body: %{"jsonrpc" => "2.0", "id" => "abc", "result" => %{}}}
    end
  end

  describe "tools/list" do
    test "answers an empty list when the registry holds no tool, with no header at all" do
      response = respond({request("tools/list"), @no_headers}, @empty)

      assert response == %{
               status: 200,
               body: %{"jsonrpc" => "2.0", "id" => 1, "result" => %{"tools" => []}}
             }
    end

    test "answers the definitions of the tools sorted by name" do
      response = respond_legacy(request("tools/list"), @full)

      names = for %{"name" => name} <- response.body["result"]["tools"], do: name
      assert names == ["alpha_refuse", "echo"]
    end

    test "answers a request of the 2026-07-28 revision with no initialize before it" do
      response = respond(modern("tools/list"), @empty)

      assert %{status: 200, body: %{"id" => 1, "result" => result}} = response
      assert result["tools"] == []
      assert result["resultType"] == "complete"
      assert result["cacheScope"] == "public"
      assert is_integer(result["ttlMs"]) and result["ttlMs"] >= 0
      assert %{"name" => "gobusgo"} = result["_meta"]["io.modelcontextprotocol/serverInfo"]
    end

    test "refuses a cursor, since the server issues none" do
      response = respond_legacy(request("tools/list", %{"cursor" => "next"}))

      assert error_code(response) == -32_602
    end
  end

  describe "tools/call" do
    test "answers the result the tool returns" do
      params = %{"name" => "echo", "arguments" => %{"text" => "hello"}}
      response = respond_legacy(request("tools/call", params), @full)

      assert response.body["result"] == %{"content" => [%{"type" => "text", "text" => "hello"}]}
    end

    test "answers a tool execution error as a result flagged isError" do
      response = respond_legacy(request("tools/call", %{"name" => "alpha_refuse"}), @full)

      assert response.status == 200

      assert response.body["result"] == %{
               "content" => [%{"type" => "text", "text" => "The stop is not served today."}],
               "isError" => true
             }
    end

    test "answers invalid params for an unknown tool, naming it" do
      params = %{"name" => "nope", "arguments" => %{}}
      response = respond_legacy(request("tools/call", params))

      assert response.status == 200
      assert error_code(response) == -32_602
      assert response.body["error"]["message"] == "Unknown tool: nope"
    end

    test "answers invalid params for arguments that break the tool's schema, without the value" do
      params = %{"name" => "echo", "arguments" => %{"text" => 1_234_567}}
      response = respond_legacy(request("tools/call", params), @full)

      assert error_code(response) == -32_602
      assert response.body["error"]["message"] =~ "text"
      refute JSON.encode!(response.body) =~ "1234567"
    end

    test "answers invalid params for a request with no tool name" do
      response = respond_legacy(request("tools/call", %{"arguments" => %{}}), @full)

      assert error_code(response) == -32_602
    end

    test "carries the 2026-07-28 result type on a tool's result, with no caching hint" do
      response =
        respond(modern("tools/call", %{"name" => "echo", "arguments" => %{"text" => "x"}}), @full)

      assert response.body["result"]["resultType"] == "complete"
      refute Map.has_key?(response.body["result"], "ttlMs")
    end
  end

  describe "resources" do
    test "resources/list answers the definitions sorted by uri" do
      response = respond_legacy(request("resources/list"), @full)

      uris = for %{"uri" => uri} <- response.body["result"]["resources"], do: uri
      assert uris == ["gobusgo://notice", "gobusgo://unavailable"]
    end

    test "resources/list answers an empty list when the registry holds no resource" do
      response = respond_legacy(request("resources/list"))

      assert response.body["result"] == %{"resources" => []}
    end

    test "resources/read answers the contents of the resource" do
      response = respond_legacy(request("resources/read", %{"uri" => "gobusgo://notice"}), @full)

      assert response.body["result"] == %{
               "contents" => [
                 %{
                   "uri" => "gobusgo://notice",
                   "mimeType" => "text/plain",
                   "text" => "No service changes."
                 }
               ]
             }
    end

    test "resources/read answers -32002 for an unknown resource to a client of an earlier revision" do
      response = respond_legacy(request("resources/read", %{"uri" => "gobusgo://nope"}), @full)

      assert response.status == 200
      assert error_code(response) == -32_002
    end

    test "resources/read answers invalid params for an unknown resource under 2026-07-28" do
      response = respond(modern("resources/read", %{"uri" => "gobusgo://nope"}), @full)

      assert error_code(response) == -32_602
      assert response.body["error"]["data"] == %{"uri" => "gobusgo://nope"}
    end

    test "resources/read answers an internal error for a resource whose source has no data" do
      params = %{"uri" => "gobusgo://unavailable"}
      response = respond_legacy(request("resources/read", params), @full)

      assert response.status == 500
      assert error_code(response) == -32_603
    end

    test "resources/read under 2026-07-28 carries caching hints that hold nothing stale" do
      response = respond(modern("resources/read", %{"uri" => "gobusgo://notice"}), @full)

      assert response.body["result"]["ttlMs"] == 0
      assert response.body["result"]["cacheScope"] == "public"
    end
  end

  describe "server/discover" do
    test "answers the supported revisions, capabilities, and instructions" do
      response = respond(modern("server/discover"), @empty)

      assert %{status: 200, body: %{"result" => result}} = response
      assert result["supportedVersions"] == [@modern, @legacy]
      assert result["capabilities"] == %{"tools" => %{}, "resources" => %{}}
      assert result["instructions"] =~ AppInfo.terms().url
      assert result["resultType"] == "complete"
      assert result["cacheScope"] == "public"
    end

    test "is an unknown method to a client of an earlier revision" do
      response = respond_legacy(request("server/discover"))

      assert response.status == 200
      assert error_code(response) == -32_601
    end
  end

  describe "a request of the 2026-07-28 revision" do
    test "is refused as invalid params with 400 when its _meta is missing" do
      headers = %{protocol_version: @modern, method: "tools/list", name: nil}

      response = respond({request("tools/list", %{}), headers}, @empty)

      assert response.status == 400
      assert error_code(response) == -32_602
    end

    test "is refused as invalid params with 400 when it declares no client capabilities" do
      meta = Map.delete(modern_meta(), "io.modelcontextprotocol/clientCapabilities")
      headers = %{protocol_version: @modern, method: "tools/list", name: nil}

      response = respond({request("tools/list", %{"_meta" => meta}), headers}, @empty)

      assert response.status == 400
      assert error_code(response) == -32_602
    end

    test "is refused as a header mismatch when the _meta names another revision" do
      meta = modern_meta(%{"io.modelcontextprotocol/protocolVersion" => @legacy})
      headers = %{protocol_version: @modern, method: "tools/list", name: nil}

      response = respond({request("tools/list", %{"_meta" => meta}), headers}, @empty)

      assert response.status == 400
      assert error_code(response) == -32_020
    end

    for {case_name, method_header} <- [
          {"the method header is missing", nil},
          {"the method header names another method", "tools/call"}
        ] do
      test "is refused as a header mismatch when #{case_name}" do
        {message, headers} = modern("tools/list")

        response = respond({message, %{headers | method: unquote(method_header)}}, @empty)

        assert response.status == 400
        assert error_code(response) == -32_020
      end
    end

    for {case_name, name_header} <- [
          {"the name header is missing", nil},
          {"the name header names another tool", "other"}
        ] do
      test "is refused as a header mismatch when #{case_name}" do
        {message, headers} =
          modern("tools/call", %{"name" => "echo", "arguments" => %{"text" => "x"}})

        response = respond({message, %{headers | name: unquote(name_header)}}, @full)

        assert response.status == 400
        assert error_code(response) == -32_020
      end
    end

    test "accepts a name header in the base64 form for a name that is not plain ASCII" do
      uri = "gobusgo://café"
      {message, headers} = modern("resources/read", %{"uri" => uri})
      encoded = "=?base64?" <> Base.encode64(uri) <> "?="

      response = respond({message, %{headers | name: encoded}}, @full)

      assert response.status == 200
      assert error_code(response) == -32_602
    end

    test "is refused with 400 and the supported revisions for a revision the server does not speak" do
      headers = %{protocol_version: "1900-01-01", method: "tools/list", name: nil}

      response = respond({request("tools/list"), headers}, @empty)

      assert response.status == 400
      assert error_code(response) == -32_022

      assert response.body["error"]["data"] ==
               %{"supported" => [@modern, @legacy], "requested" => "1900-01-01"}
    end
  end

  describe "a request that is malformed" do
    test "is a parse error with 400 and a null id when the body is not JSON" do
      response = Server.respond(%{body: "{not json", headers: @no_headers}, @empty)

      assert response.status == 400
      assert response.body["id"] == nil
      assert error_code(response) == -32_700
    end

    test "is an invalid request with 400 when the body is a batch" do
      response = Server.respond(%{body: "[]", headers: @no_headers}, @empty)

      assert response.status == 400
      assert error_code(response) == -32_600
    end

    for {case_name, message} <- [
          {"it names no jsonrpc version", %{"id" => 1, "method" => "ping"}},
          {"its method is not a string", %{"jsonrpc" => "2.0", "id" => 1, "method" => 5}},
          {"its id is null", %{"jsonrpc" => "2.0", "id" => nil, "method" => "ping"}},
          {"its id is a list", %{"jsonrpc" => "2.0", "id" => [1], "method" => "ping"}},
          {"it is a response", %{"jsonrpc" => "2.0", "id" => 1, "result" => %{}}}
        ] do
      test "is an invalid request with 400 when #{case_name}" do
        body = JSON.encode!(unquote(Macro.escape(message)))
        response = Server.respond(%{body: body, headers: @no_headers}, @empty)

        assert response.status == 400
        assert error_code(response) == -32_600
      end
    end

    test "echoes the id of an invalid request when it can be read" do
      message = %{"id" => 9, "method" => "ping"}
      response = Server.respond(%{body: JSON.encode!(message), headers: @no_headers}, @empty)

      assert response.body["id"] == 9
    end

    test "is invalid params when params is not an object" do
      message = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => [1]}

      response = respond({message, legacy_headers()}, @empty)

      assert error_code(response) == -32_602
    end
  end

  describe "an unknown method" do
    test "is method not found, answered with 200 to a client of an earlier revision" do
      response = respond_legacy(request("tools/unheard-of"))

      assert response.status == 200
      assert error_code(response) == -32_601
      assert response.body["id"] == 1
    end

    test "is method not found, answered with 404 under 2026-07-28" do
      response = respond(modern("tools/unheard-of"), @empty)

      assert response.status == 404
      assert error_code(response) == -32_601
    end
  end
end
