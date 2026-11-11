defmodule GobusgoWeb.Mcp.Tools.FindTest do
  # Calls the tool as the endpoint does after it has checked the arguments
  # against `arguments_schema/0`, over the application's global views, which
  # the test fills with Gobusgo.Test.TransitSeeds, hence the non-async case.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Gobusgo.Schema
  alias Gobusgo.Test.TransitSeeds
  alias GobusgoWeb.Mcp.Tools.Find
  alias GobusgoWeb.TransitQuery

  setup do
    TransitSeeds.restart_views()
    on_exit(&TransitSeeds.restart_views/0)

    :ok = TransitSeeds.agencies([{"40", "Sound Transit"}, {"1", "Metro Transit"}])

    :ok =
      TransitSeeds.routes("1", [
        {"1_100", "8", "Seattle Center - Capitol Hill"},
        {"1_200", "40", "Northgate - Ballard"}
      ])

    :ok = TransitSeeds.stops("1_100", [{"1_3", "Capitol Hill Station", "300"}])
  end

  defp find(query) do
    {:ok, %{"structuredContent" => structured} = result} = Find.call(%{"query" => query})
    {result, structured}
  end

  describe "call/1" do
    test "answers the agencies and routes the filter bar suggests for the same text" do
      {_result, %{"data" => data}} = find("40")

      bar =
        TransitQuery.filter_bar(%{
          filter: %{},
          query: "40",
          agencies: TransitQuery.agencies(),
          route_fetches: TransitQuery.route_fetches()
        })

      assert Enum.map(data["agencies"] ++ data["routes"], & &1["id"]) ==
               Enum.map(bar.suggestions, & &1.id)
    end

    test "answers an agency with its identifier and name" do
      {_result, %{"data" => data}} = find("metro")

      assert data["agencies"] == [%{"id" => "1", "name" => "Metro Transit"}]
    end

    test "answers a route with its names and its agency's name" do
      {_result, %{"data" => data}} = find("8")

      assert data["routes"] == [
               %{
                 "id" => "1_100",
                 "name" => "8",
                 "detail" => "Seattle Center - Capitol Hill",
                 "agencyName" => "Metro Transit"
               }
             ]
    end

    test "answers a stop with its name, code, direction, and position" do
      {_result, %{"data" => data}} = find("capitol")

      assert data["stops"] == [
               %{
                 "id" => "1_3",
                 "name" => "Capitol Hill Station",
                 "code" => "300",
                 "direction" => "N",
                 "lat" => 47.6,
                 "lon" => -122.3
               }
             ]
    end

    test "names the fetch in meta with the count of the items" do
      {_result, %{"meta" => meta}} = find("capitol")

      assert %{"fetchedAt" => fetched_at, "requestId" => request_id, "count" => 1} = meta
      assert {:ok, %DateTime{}, 0} = DateTime.from_iso8601(fetched_at)
      assert is_binary(request_id)
      assert %{"restCount" => 0, "stopRestCount" => 0} = meta
    end

    test "carries the same answer as structured content and as text" do
      {result, structured} = find("capitol")

      assert %{"content" => [%{"type" => "text", "text" => text}]} = result
      assert JSON.decode!(text) == structured
    end

    test "answers nothing for text that names nothing" do
      {_result, %{"data" => data, "meta" => %{"count" => 0}}} = find("zzz")

      assert data == %{"agencies" => [], "routes" => [], "stops" => []}
    end

    test "holds at most the bound of items in each list" do
      stops = for number <- 1..120, do: {"1_s#{number}", "Stop #{number}", nil}
      :ok = TransitSeeds.stops("1_100", stops)

      {_result, %{"data" => %{"stops" => kept}, "meta" => meta}} = find("stop")

      assert length(kept) == 100
      assert meta["stopRestCount"] == 20
    end

    test "gives the same answer to a call between fetches" do
      {_first, first} = find("capitol")
      {_second, second} = find("capitol")

      assert first == second
    end

    test "gives a newer fetch's answer once it arrives" do
      {_before, %{"data" => %{"agencies" => []}}} = find("rapid")

      :ok = TransitSeeds.agencies([{"1", "Metro Transit"}, {"3", "RapidRide Transit"}])

      assert {_after, %{"data" => %{"agencies" => [%{"id" => "3"}]}}} = find("rapid")
    end

    test "answers an error to be acted on before the agency view has a fetch" do
      TransitSeeds.restart_views()

      assert {:error, text} = Find.call(%{"query" => "metro"})
      assert text =~ "No agency data is available yet"
    end

    test "narrows text longer than the page's text bar to its length" do
      long = String.duplicate("a", 200)

      assert {:ok, %{"structuredContent" => %{"data" => %{"stops" => []}}}} =
               Find.call(%{"query" => long})
    end
  end

  describe "arguments_schema/0" do
    test "accepts a query" do
      assert Schema.mismatch(%{"query" => "metro"}, Find.arguments_schema()) == nil
    end

    test "refuses a call with no query" do
      assert %{path: ["query"], expected: :required} =
               Schema.mismatch(%{}, Find.arguments_schema())
    end

    test "refuses a query that is not text" do
      assert %{path: ["query"]} = Schema.mismatch(%{"query" => 40}, Find.arguments_schema())
    end
  end

  describe "definition/0" do
    test "names the terms and credits the data as provided as is" do
      %{"description" => description} = Find.definition()

      assert description =~ "https://www.soundtransit.org"
      assert description =~ ~s(as is)
    end

    test "carries an output schema over data and meta" do
      assert %{"outputSchema" => %{"properties" => %{"data" => _data, "meta" => _meta}}} =
               Find.definition()
    end
  end
end
