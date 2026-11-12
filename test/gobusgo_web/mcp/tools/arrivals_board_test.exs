defmodule GobusgoWeb.Mcp.Tools.ArrivalsBoardTest do
  # Calls the tool as the endpoint does after it has checked the arguments
  # against `arguments_schema/0`, and compares its answer with the
  # `arrivals` tool's over the application's global views, hold supervisor,
  # and demand registry, all of it global state, hence the non-async case.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Gobusgo.Demand
  alias Gobusgo.OneBusAway.DemandKey
  alias Gobusgo.Schema
  alias Gobusgo.Test.TransitSeeds
  alias GobusgoWeb.Mcp.Registry
  alias GobusgoWeb.Mcp.Resources.ArrivalsBoard
  alias GobusgoWeb.Mcp.Server
  alias GobusgoWeb.Mcp.StopHolds
  alias GobusgoWeb.Mcp.Tools.Arrivals
  alias GobusgoWeb.Mcp.Tools.ArrivalsBoard, as: Board
  alias GobusgoWeb.Mcp.Tools.PlanTrip

  @legacy "2025-11-25"
  @registry Registry.new(%{tools: [Board], resources: [ArrivalsBoard]})

  setup do
    TransitSeeds.restart_views()

    on_exit(fn ->
      Enum.each(StopHolds.held_stop_ids(), &StopHolds.release/1)
      TransitSeeds.restart_views()
    end)

    :ok = TransitSeeds.stops("1_100", [{"1_1", "Pine Street", nil}, {"1_2", "Union Street", nil}])
  end

  defp list_tool do
    message = %{"jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => %{}}

    %{body: %{"result" => %{"tools" => [tool]}}} =
      Server.respond(
        %{
          body: JSON.encode!(message),
          headers: %{protocol_version: @legacy, method: nil, name: nil}
        },
        @registry
      )

    tool
  end

  defp board(stop_id) do
    {:ok, %{"structuredContent" => structured} = result} = Board.call(%{"stopId" => stop_id})
    {result, structured}
  end

  defp arrivals(stop_id) do
    {:ok, %{"structuredContent" => structured}} = Arrivals.call(%{"stopId" => stop_id})
    structured
  end

  describe "tools/list" do
    test "lists arrivals_board with the app it renders in" do
      tool = list_tool()

      assert tool["name"] == "arrivals_board"
      assert tool["_meta"] == %{"ui" => %{"resourceUri" => "ui://gobusgo/arrivals-board"}}
    end

    test "takes a stop identifier, which it requires, and optionally a time and routes" do
      tool = list_tool()

      assert Map.keys(tool["inputSchema"]["properties"]) == ["route", "stopId", "when"]
      assert tool["inputSchema"]["required"] == ["stopId"]
    end

    test "describes its time as plan_trip describes its own" do
      plan_trip_when = PlanTrip.definition()["inputSchema"]["properties"]["when"]

      assert list_tool()["inputSchema"]["properties"]["when"] == plan_trip_when
    end

    test "bounds the routes it takes" do
      %{"route" => route} = list_tool()["inputSchema"]["properties"]

      assert %{"type" => "array", "maxItems" => 10, "items" => %{"type" => "string"}} = route
      assert route["items"]["minLength"] == 1
      assert route["items"]["maxLength"] == 100
    end

    test "accepts the stop alone, as arrivals does" do
      assert Schema.mismatch(%{"stopId" => "1_1"}, Board.arguments_schema()) == nil
    end

    test "accepts the stop with a time and routes" do
      arguments = %{
        "stopId" => "1_1",
        "when" => %{"mode" => "departAt", "time" => "23:00"},
        "route" => ["1_100"]
      }

      assert Schema.mismatch(arguments, Board.arguments_schema()) == nil
    end

    test "rejects a time that is not an object" do
      arguments = %{"stopId" => "1_1", "when" => "tonight"}

      assert Schema.mismatch(arguments, Board.arguments_schema()) != nil
    end

    test "rejects routes that are not a list" do
      arguments = %{"stopId" => "1_1", "route" => "1_100"}

      assert Schema.mismatch(arguments, Board.arguments_schema()) != nil
    end

    test "describes a stop name its output schema holds" do
      %{"outputSchema" => %{"properties" => %{"data" => %{"properties" => properties}}}} =
        list_tool()

      assert %{"stopName" => %{"type" => "string"}, "status" => _status} = properties
    end
  end

  describe "tools/call" do
    test "answers what arrivals answers for a stop with a fetch, with the stop's name" do
      :ok = TransitSeeds.arrivals("1_1", [{"soon", 5}, {"late", 20}])

      {_result, %{"data" => data, "meta" => meta}} = board("1_1")
      %{"data" => arrivals_data, "meta" => arrivals_meta} = arrivals("1_1")

      assert data == Map.put(arrivals_data, "stopName", "Pine Street")
      assert meta == arrivals_meta
    end

    test "carries the same answer as structured content and as text" do
      :ok = TransitSeeds.arrivals("1_1", [{"soon", 5}])

      {result, structured} = board("1_1")

      assert %{"content" => [%{"type" => "text", "text" => text}]} = result
      assert JSON.decode!(text) == structured
    end

    test "answers fetching with the name of a stop that has no fetch" do
      {_result, %{"data" => data}} = board("1_2")

      assert %{"status" => "fetching", "stopName" => "Union Street", "retryAfterSeconds" => _} =
               data
    end

    test "answers unknown_stop with no name" do
      {_result, %{"data" => data}} = board("9_9")

      assert data == %{"status" => "unknown_stop", "stopId" => "9_9"}
    end

    test "holds the stop like every arrivals call" do
      :ok = TransitSeeds.arrivals("1_1", [{"soon", 5}])

      board("1_1")

      assert Demand.items(Demand, DemandKey.arrivals_dataset()) == ["1_1"]
    end

    test "answers capacity_reached at the cap, as arrivals does" do
      for number <- 1..StopHolds.hold_count_max() do
        :held = StopHolds.hold("other-#{number}", %{hold_ms: StopHolds.hold_ms()})
      end

      {_result, %{"data" => data}} = board("1_1")

      assert %{"status" => "capacity_reached", "stopId" => "1_1", "retryAfterSeconds" => 60} =
               data
    end

    test "refuses an empty stop identifier as arrivals does" do
      assert Board.call(%{"stopId" => ""}) == Arrivals.call(%{"stopId" => ""})
    end

    test "answers what it answers with no time when it is given a time and routes" do
      :ok = TransitSeeds.arrivals("1_1", [{"soon", 5}])
      arguments = %{"stopId" => "1_1", "when" => %{"mode" => "departAt", "time" => "23:00"}}

      assert Board.call(Map.put(arguments, "route", ["1_100"])) ==
               Board.call(%{"stopId" => "1_1"})
    end

    test "refuses a time plan_trip refuses, with plan_trip's message" do
      for when_argument <- [
            %{"mode" => "teleport"},
            %{"mode" => "departAt", "day" => "friday", "time" => "08:30"},
            %{"mode" => "departAt"},
            %{"mode" => "arriveBy", "time" => "25:00"}
          ] do
        {:error, message} = Board.call(%{"stopId" => "1_1", "when" => when_argument})

        assert {:error, ^message} =
                 PlanTrip.call(%{"to" => "Pine", "when" => when_argument})
      end
    end

    test "accepts a time of mode now with no clock" do
      :ok = TransitSeeds.arrivals("1_1", [{"soon", 5}])

      assert {:ok, _result} = Board.call(%{"stopId" => "1_1", "when" => %{"mode" => "now"}})
    end

    test "refuses routes past the bound, a blank route, and a route past its length" do
      too_many = Enum.map(1..11, &"1_#{&1}")

      for route <- [too_many, [""], [String.duplicate("1", 101)]] do
        assert {:error, text} =
                 Board.call(%{
                   "stopId" => "1_1",
                   "when" => %{"mode" => "departAt", "time" => "23:00"},
                   "route" => route
                 })

        assert text =~ "route"
      end
    end

    test "leaves routes with no time to the live board, which ignores them" do
      :ok = TransitSeeds.arrivals("1_1", [{"soon", 5}])

      assert Board.call(%{"stopId" => "1_1", "route" => ["1_100"]}) ==
               Board.call(%{"stopId" => "1_1"})
    end
  end
end
