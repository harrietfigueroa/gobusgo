defmodule GobusgoWeb.Mcp.Tools.PlanTripTest do
  # Calls the tool the way the endpoint does, through the request-level
  # handlers of `GobusgoWeb.Mcp.Server`, with the registry that holds it and
  # its app, and reads the answer a client reads. The endpoint's schema
  # check runs first, so a call the schema refuses never reaches the tool.
  use ExUnit.Case, async: true

  alias GobusgoWeb.Mcp.Registry
  alias GobusgoWeb.Mcp.Resources.TripApp
  alias GobusgoWeb.Mcp.Server
  alias GobusgoWeb.Mcp.Tools.PlanTrip

  @legacy "2025-11-25"
  @registry Registry.new(%{tools: [PlanTrip], resources: [TripApp]})

  defp rpc(method, params) do
    %{"jsonrpc" => "2.0", "id" => 1, "method" => method, "params" => params}
  end

  defp respond(message) do
    request = %{
      body: JSON.encode!(message),
      headers: %{protocol_version: @legacy, method: nil, name: nil}
    }

    Server.respond(request, @registry)
  end

  defp call_tool(arguments) do
    respond(rpc("tools/call", %{"name" => "plan_trip", "arguments" => arguments}))
  end

  describe "tools/list" do
    test "lists plan_trip with the app it renders in" do
      %{body: %{"result" => %{"tools" => [tool]}}} = respond(rpc("tools/list", %{}))

      assert tool["name"] == "plan_trip"
      assert tool["_meta"] == %{"ui" => %{"resourceUri" => "ui://gobusgo/plan-trip"}}
    end

    test "names the three arguments and requires the destination" do
      %{body: %{"result" => %{"tools" => [tool]}}} = respond(rpc("tools/list", %{}))

      assert Map.keys(tool["inputSchema"]["properties"]) == ["from", "to", "when"]
      assert tool["inputSchema"]["required"] == ["to"]
    end

    test "links a resource the server lists" do
      %{body: %{"result" => %{"tools" => [tool]}}} = respond(rpc("tools/list", %{}))
      %{body: %{"result" => %{"resources" => resources}}} = respond(rpc("resources/list", %{}))

      linked = tool["_meta"]["ui"]["resourceUri"]

      assert linked in Enum.map(resources, & &1["uri"])
    end
  end

  describe "tools/call" do
    test "returns the arguments unchanged as structuredContent" do
      arguments = %{
        "from" => "Pine and 3rd",
        "to" => "Seattle-Tacoma Airport",
        "when" => %{"mode" => "arriveBy", "day" => "tomorrow", "time" => "08:30"}
      }

      %{status: 200, body: %{"result" => result}} = call_tool(arguments)

      assert result["structuredContent"] == arguments
    end

    test "returns one line of text" do
      %{body: %{"result" => result}} = call_tool(%{"from" => "Pine and 3rd", "to" => "Ballard"})

      assert result["content"] == [
               %{"type" => "text", "text" => "Planning a trip from Pine and 3rd to Ballard."}
             ]
    end

    test "accepts a missing from and plans a trip to the destination" do
      %{status: 200, body: %{"result" => result}} = call_tool(%{"to" => "B"})

      assert result["content"] == [%{"type" => "text", "text" => "Planning a trip to B."}]
      assert result["structuredContent"] == %{"to" => "B"}
    end

    test "accepts a blank from and returns it unchanged" do
      %{status: 200, body: %{"result" => result}} = call_tool(%{"from" => "  ", "to" => "B"})

      assert result["content"] == [%{"type" => "text", "text" => "Planning a trip to B."}]
      assert result["structuredContent"] == %{"from" => "  ", "to" => "B"}
    end

    test "leaves out a when the rider gave none" do
      %{body: %{"result" => result}} = call_tool(%{"from" => "A", "to" => "B"})

      assert result["structuredContent"] == %{"from" => "A", "to" => "B"}
    end

    test "accepts leaving now with no time" do
      %{body: %{"result" => result}} =
        call_tool(%{"from" => "A", "to" => "B", "when" => %{"mode" => "now"}})

      assert result["structuredContent"]["when"] == %{"mode" => "now"}
    end

    test "drops an argument the schema does not name" do
      %{body: %{"result" => result}} =
        call_tool(%{"from" => "A", "to" => "B", "mode" => "bus"})

      assert result["structuredContent"] == %{"from" => "A", "to" => "B"}
    end
  end

  describe "refused arguments" do
    test "answers invalid params for a missing destination" do
      assert %{body: %{"error" => %{"code" => -32_602}}} = call_tool(%{"from" => "A"})
    end

    test "answers invalid params for an end that is not text" do
      assert %{body: %{"error" => %{"code" => -32_602}}} = call_tool(%{"from" => "A", "to" => 7})
    end

    for {name, arguments} <- [
          {"a blank destination", %{"from" => "A", "to" => "  "}},
          {"a destination past the length limit",
           %{"from" => "A", "to" => String.duplicate("b", 201)}},
          {"a start past the length limit", %{"from" => String.duplicate("a", 201), "to" => "B"}},
          {"an unknown mode", %{"from" => "A", "to" => "B", "when" => %{"mode" => "teleport"}}},
          {"an unknown day",
           %{
             "from" => "A",
             "to" => "B",
             "when" => %{"mode" => "departAt", "day" => "friday", "time" => "08:30"}
           }},
          {"departAt with no time",
           %{"from" => "A", "to" => "B", "when" => %{"mode" => "departAt"}}},
          {"arriveBy with a time no clock shows",
           %{"from" => "A", "to" => "B", "when" => %{"mode" => "arriveBy", "time" => "25:00"}}},
          {"a time with a meridiem",
           %{"from" => "A", "to" => "B", "when" => %{"mode" => "departAt", "time" => "8:30 pm"}}}
        ] do
      test "answers a tool error for #{name}" do
        %{status: 200, body: %{"result" => result}} = call_tool(unquote(Macro.escape(arguments)))

        assert result["isError"] == true
        assert [%{"type" => "text", "text" => text}] = result["content"]
        assert text != ""
      end
    end
  end
end
