defmodule Gobusgo.OneBusAway.RouteItemsTest do
  # Reads the items of two fetch views started and seeded for each test, so
  # every case states what the views hold and compares the whole list read.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RouteItems
  alias Gobusgo.OneBusAway.RoutePathBatch
  alias Gobusgo.Test.RouteViewSeeds

  @fetched_at ~U[2026-10-05 12:00:00Z]
  @noted_at ~U[2026-10-05 12:30:00Z]

  setup context do
    route_view = Module.concat(__MODULE__, "RouteView#{context.line}")
    route_path_view = Module.concat(__MODULE__, "RoutePathView#{context.line}")

    for {view, records} <- [
          {route_view, RouteBatch.Records},
          {route_path_view, RoutePathBatch.Records}
        ] do
      start_supervised!(
        {FetchView, name: view, pubsub: Gobusgo.PubSub, records: records, id_count_max: 100}
      )
    end

    %{route_view: route_view, route_path_view: route_path_view}
  end

  defp read(context, agency_ids) do
    RouteItems.read(%{
      agency_ids: agency_ids,
      route_view: context.route_view,
      route_path_view: context.route_path_view
    })
  end

  describe "read/1" do
    test "returns nothing for no agencies", context do
      assert read(context, []) == []
    end

    test "returns an agency whose routes have no fetch with no attempt time", context do
      assert read(context, ["40"]) == [%{item: {:routes, "40"}, attempted_at: nil}]
    end

    test "returns the agencies before the routes, each in identifier order", context do
      RouteViewSeeds.routes(context.route_view, %{
        agency_id: "40",
        route_ids: ["40_b", "40_a"],
        fetched_at: @fetched_at
      })

      RouteViewSeeds.routes(context.route_view, %{
        agency_id: "1",
        route_ids: ["1_a"],
        fetched_at: @fetched_at
      })

      assert Enum.map(read(context, ["40", "1"]), & &1.item) == [
               {:routes, "1"},
               {:routes, "40"},
               {:route_path, "1_a"},
               {:route_path, "40_a"},
               {:route_path, "40_b"}
             ]
    end

    test "returns the fetch time of an item's current fetch as its attempt time", context do
      RouteViewSeeds.routes(context.route_view, %{
        agency_id: "40",
        route_ids: ["40_a", "40_b"],
        fetched_at: @fetched_at
      })

      RouteViewSeeds.route_path(context.route_path_view, %{
        route_id: "40_a",
        fetched_at: @fetched_at
      })

      assert read(context, ["40"]) == [
               %{item: {:routes, "40"}, attempted_at: @fetched_at},
               %{item: {:route_path, "40_a"}, attempted_at: @fetched_at},
               %{item: {:route_path, "40_b"}, attempted_at: nil}
             ]
    end

    test "returns the time of a noted attempt for an item with no fetch", context do
      :ok = FetchView.note_attempt(context.route_view, %{id: "40", fetched_at: @noted_at})

      assert read(context, ["40"]) == [%{item: {:routes, "40"}, attempted_at: @noted_at}]
    end

    test "leaves out the routes of an agency it is not given", context do
      RouteViewSeeds.routes(context.route_view, %{
        agency_id: "1",
        route_ids: ["1_a"],
        fetched_at: @fetched_at
      })

      assert read(context, ["40"]) == [%{item: {:routes, "40"}, attempted_at: nil}]
    end

    test "returns a route two agencies list once", context do
      for agency_id <- ["1", "40"] do
        RouteViewSeeds.routes(context.route_view, %{
          agency_id: agency_id,
          route_ids: ["shared"],
          fetched_at: @fetched_at
        })
      end

      assert Enum.count(read(context, ["1", "40"]), &(&1.item == {:route_path, "shared"})) == 1
    end

    test "refuses more agencies than its bound", context do
      agency_ids = for index <- 0..RouteItems.agency_count_max(), do: "agency-#{index}"

      assert_raise AssertionError, ~r/at most 64 agencies/, fn -> read(context, agency_ids) end
    end
  end
end
