defmodule Gobusgo.OneBusAway.ReadinessTest do
  # Reads the readiness of two fetch views started and seeded for each test,
  # with the agency fetch given as a function, so every case states what the
  # views hold and compares the one answer.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.Readiness
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RoutePathBatch
  alias Gobusgo.Test.RouteViewSeeds

  # Two days before any slot came last, so a fetch made then is due again.
  @stale ~U[2026-10-03 12:00:00Z]
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

  defp read(context, agency_fetch) do
    Readiness.read(
      agency_fetch: fn -> agency_fetch end,
      route_view: context.route_view,
      route_path_view: context.route_path_view
    )
  end

  defp seed_routes(context, agency_id, route_ids) do
    RouteViewSeeds.routes(context.route_view, %{
      agency_id: agency_id,
      route_ids: route_ids,
      fetched_at: @stale
    })
  end

  defp seed_route_path(context, route_id) do
    RouteViewSeeds.route_path(context.route_path_view, %{route_id: route_id, fetched_at: @stale})
  end

  describe "read/1" do
    test "is filling while the agency view has no fetch", context do
      assert read(context, nil) == {:filling, :agency_fetch_absent}
    end

    test "is filling while an agency's routes have no attempt", context do
      seed_routes(context, "1", [])

      assert read(context, %{agency_ids: ["1", "40"]}) ==
               {:filling, {:route_items_unattempted, 1}}
    end

    test "is filling while a listed route's path has no attempt", context do
      seed_routes(context, "40", ["40_a", "40_b", "40_c"])
      seed_route_path(context, "40_a")

      assert read(context, %{agency_ids: ["40"]}) == {:filling, {:route_items_unattempted, 2}}
    end

    test "is ready once every agency and every listed route has a fetch", context do
      seed_routes(context, "40", ["40_a"])
      seed_route_path(context, "40_a")

      assert read(context, %{agency_ids: ["40"]}) == :ready
    end

    test "is ready with an item whose noted attempt has not reached its view", context do
      seed_routes(context, "40", ["40_a"])
      :ok = FetchView.note_attempt(context.route_path_view, %{id: "40_a", fetched_at: @noted_at})

      assert read(context, %{agency_ids: ["40"]}) == :ready
    end

    test "is ready with a fetch of no agencies", context do
      assert read(context, %{agency_ids: []}) == :ready
    end
  end
end
