defmodule GobusgoWeb.Mcp.Tools.RouteTest do
  # Calls the tool as the endpoint does after it has checked the arguments
  # against `arguments_schema/0`, over the application's global views, which
  # the test fills with Gobusgo.Test.TransitSeeds, hence the non-async case.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.Schema
  alias Gobusgo.Test.TransitSeeds
  alias GobusgoWeb.Mcp.Tools.Route

  @route_path_view Gobusgo.OneBusAway.RoutePathView

  setup do
    TransitSeeds.restart_views()
    on_exit(&TransitSeeds.restart_views/0)

    :ok = TransitSeeds.routes("1", [{"1_100", "8", "Seattle Center - Capitol Hill"}])

    :ok =
      TransitSeeds.stops("1_100", [
        {"1_1", "Pine Street", "100"},
        {"1_2", "Union Street", "200"},
        {"1_3", "Madison Street", nil}
      ])
  end

  defp route(route_id) do
    {:ok, %{"structuredContent" => structured} = result} = Route.call(%{"routeId" => route_id})
    {result, structured}
  end

  defp stop_ids(direction), do: Enum.map(direction["stops"], & &1["id"])

  describe "call/1" do
    test "answers the directions of a route with their stops in the order the route serves them" do
      :ok =
        TransitSeeds.route_path("1_100", [
          {"Capitol Hill", ["1_3", "1_1"]},
          {"Seattle Center", ["1_2", "1_1"]}
        ])

      {_result, %{"data" => data}} = route("1_100")

      assert %{"status" => "route", "routeId" => "1_100", "directions" => [capitol, center]} =
               data

      assert capitol["name"] == "Capitol Hill"
      assert stop_ids(capitol) == ["1_3", "1_1"]
      assert center["name"] == "Seattle Center"
      assert stop_ids(center) == ["1_2", "1_1"]
    end

    test "answers the route's agency and names" do
      :ok = TransitSeeds.route_path("1_100", [{"Capitol Hill", ["1_1"]}])

      {_result, %{"data" => data}} = route("1_100")

      assert %{
               "agencyId" => "1",
               "shortName" => "8",
               "longName" => "Seattle Center - Capitol Hill"
             } = data
    end

    test "gives a stop its identifier, name, code, and the direction it faces" do
      :ok = TransitSeeds.route_path("1_100", [{"Capitol Hill", ["1_1", "1_3"]}])

      {_result, %{"data" => %{"directions" => [%{"stops" => [pine, madison]}]}}} =
        route("1_100")

      assert pine == %{
               "id" => "1_1",
               "name" => "Pine Street",
               "code" => "100",
               "direction" => "N"
             }

      assert %{"id" => "1_3", "code" => nil} = madison
    end

    test "answers a route with one direction" do
      :ok = TransitSeeds.route_path("1_100", [{"Capitol Hill", ["1_1", "1_2"]}])

      {_result, %{"data" => %{"directions" => directions}, "meta" => meta}} = route("1_100")

      assert [%{"stopCount" => 2}] = directions
      assert %{"count" => 2, "restCount" => 0} = meta
    end

    test "answers a route with no direction" do
      :ok = TransitSeeds.route_path("1_100", [])

      {_result, %{"data" => data, "meta" => meta}} = route("1_100")

      assert %{"status" => "route", "directions" => []} = data
      assert %{"count" => 0, "restCount" => 0} = meta
    end

    test "names the route path fetch in meta" do
      :ok = TransitSeeds.route_path("1_100", [{"Capitol Hill", ["1_1"]}])

      {_result, %{"meta" => meta}} = route("1_100")

      %{request_id: request_id} = FetchView.current_fetch(@route_path_view, "1_100")
      assert %{"requestId" => ^request_id, "fetchedAt" => fetched_at} = meta
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(fetched_at)
    end

    test "holds at most the bound of stops in a direction and counts the rest" do
      stops = for number <- 1..120, do: {"1_s#{number}", "Stop #{number}", nil}
      :ok = TransitSeeds.stops("1_100", stops)
      :ok = TransitSeeds.route_path("1_100", [{"Long", Enum.map(stops, &elem(&1, 0))}])

      {_result, %{"data" => %{"directions" => [direction]}, "meta" => meta}} = route("1_100")

      assert length(direction["stops"]) == 100
      assert direction["stopCount"] == 120
      assert %{"count" => 100, "restCount" => 20} = meta
    end

    test "answers unknown_route for a route no agency lists" do
      {_result, %{"data" => data, "meta" => meta}} = route("1_999")

      assert data == %{"status" => "unknown_route", "routeId" => "1_999"}
      assert %{"count" => 0, "fetchedAt" => nil, "requestId" => nil} = meta
    end

    test "carries the same answer as structured content and as text" do
      :ok = TransitSeeds.route_path("1_100", [{"Capitol Hill", ["1_1"]}])

      {result, structured} = route("1_100")

      assert %{"content" => [%{"type" => "text", "text" => text}]} = result
      assert JSON.decode!(text) == structured
    end

    test "gives a newer fetch's answer once it arrives" do
      :ok = TransitSeeds.route_path("1_100", [{"Capitol Hill", ["1_1"]}])
      {_before, before} = route("1_100")

      :ok = TransitSeeds.route_path("1_100", [{"Capitol Hill", ["1_2"]}])
      {_after, answer} = route("1_100")

      assert [direction] = before["data"]["directions"]
      assert stop_ids(direction) == ["1_1"]
      assert [direction] = answer["data"]["directions"]
      assert stop_ids(direction) == ["1_2"]
    end

    test "answers an error to be acted on while the route view holds no fetch" do
      TransitSeeds.restart_views()

      assert {:error, text} = Route.call(%{"routeId" => "1_100"})
      assert text =~ "No route data is available yet"
    end

    test "answers an error to be acted on for a listed route whose paths are not fetched" do
      assert {:error, text} = Route.call(%{"routeId" => "1_100"})
      assert text =~ "No route data is available yet"
    end

    test "refuses an empty route identifier" do
      assert {:error, text} = Route.call(%{"routeId" => ""})
      assert text =~ "empty"
    end
  end

  describe "arguments_schema/0" do
    test "accepts a route identifier and refuses anything else" do
      schema = Route.arguments_schema()

      assert Schema.mismatch(%{"routeId" => "1_100"}, schema) == nil
      assert %{path: ["routeId"]} = Schema.mismatch(%{"routeId" => 1}, schema)
      assert Schema.mismatch(%{}, schema) != nil
    end
  end

  describe "definition/0" do
    test "names the terms and credits the data as provided as is" do
      %{"description" => description} = Route.definition()

      assert description =~ "https://www.soundtransit.org"
      assert description =~ ~s(as is)
    end

    test "requires routeId and no other field" do
      assert %{
               "inputSchema" => %{
                 "properties" => properties,
                 "required" => ["routeId"],
                 "additionalProperties" => false
               }
             } = Route.definition()

      assert Map.keys(properties) == ["routeId"]
    end

    test "has an output schema" do
      assert %{"outputSchema" => %{"properties" => %{"data" => _data}}} = Route.definition()
    end
  end
end
