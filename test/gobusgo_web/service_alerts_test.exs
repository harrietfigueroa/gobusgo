defmodule GobusgoWeb.ServiceAlertsTest do
  # Builds the alerts a page shows from situation fetches written out here,
  # one rule at a time: which alerts are current and which upcoming at a
  # given time, which routes keep them, how a repeated situation is read
  # once, and what the popups are given per route.
  use ExUnit.Case, async: true

  alias GobusgoWeb.ServiceAlerts

  @now ~U[2026-10-15 16:00:00Z]
  @now_ms DateTime.to_unix(@now, :millisecond)
  @hour_ms 60 * 60 * 1_000
  @day_ms 24 * @hour_ms

  defp situation(overrides) do
    Map.merge(
      %{
        id: "40_1",
        summary: "Detour",
        description: "Use the stop on 4th Ave.",
        url: "https://example.test/detour",
        reason: "CONSTRUCTION",
        creation_time_ms: @now_ms - @day_ms,
        active_windows: [],
        affects: [%{agency_id: "40", route_id: "40_100479", stop_id: nil}]
      },
      overrides
    )
  end

  defp fetch(situations, fetched_at \\ @now) do
    %{id: "40", fetched_at: fetched_at, situations: situations}
  end

  defp alerts(fetches, overrides \\ %{}) do
    ServiceAlerts.alerts(
      Map.merge(
        %{
          situation_fetches: fetches,
          kept_route_ids: :every,
          route_names: %{"40_100479" => "1 Line"},
          now: @now
        },
        overrides
      )
    )
  end

  defp ids(alerts), do: Enum.map(alerts, & &1.id)

  describe "alerts/1 current and upcoming" do
    for {name, windows} <- [
          {"no active window", []},
          {"a window around now", [%{from_ms: @now_ms - @hour_ms, to_ms: @now_ms + @hour_ms}]},
          {"a window with no end that began", [%{from_ms: @now_ms - @hour_ms, to_ms: nil}]},
          {"a window with no start that has not ended", [%{from_ms: nil, to_ms: @now_ms + 1}]},
          {"one of several windows around now",
           [
             %{from_ms: @now_ms - 2 * @day_ms, to_ms: @now_ms - @day_ms},
             %{from_ms: @now_ms - @hour_ms, to_ms: nil}
           ]}
        ] do
      test "is current with #{name}" do
        windows = unquote(Macro.escape(windows))

        assert %{current: [%{id: "40_1"}], upcoming: []} =
                 alerts([fetch([situation(%{active_windows: windows})])])
      end
    end

    test "is upcoming, with its start, when its next window starts within seven days" do
      starts_ms = @now_ms + 2 * @day_ms
      windows = [%{from_ms: starts_ms, to_ms: starts_ms + @day_ms}]

      assert %{current: [], upcoming: [alert]} =
               alerts([fetch([situation(%{active_windows: windows})])])

      assert alert.starts_at == DateTime.from_unix!(starts_ms, :millisecond)
    end

    test "is upcoming from the nearest of its windows that start later" do
      nearest_ms = @now_ms + @day_ms

      windows = [
        %{from_ms: @now_ms + 3 * @day_ms, to_ms: nil},
        %{from_ms: nearest_ms, to_ms: nearest_ms + @hour_ms}
      ]

      assert %{upcoming: [alert]} = alerts([fetch([situation(%{active_windows: windows})])])
      assert alert.starts_at == DateTime.from_unix!(nearest_ms, :millisecond)
    end

    for {name, windows} <- [
          {"every window has ended", [%{from_ms: @now_ms - @day_ms, to_ms: @now_ms - 1}]},
          {"its next window starts after seven days",
           [%{from_ms: @now_ms + 7 * @day_ms + 1, to_ms: nil}]}
        ] do
      test "is left out when #{name}" do
        windows = unquote(Macro.escape(windows))

        assert %{current: [], upcoming: []} =
                 alerts([fetch([situation(%{active_windows: windows})])])
      end
    end

    test "orders current alerts by creation, the newest first" do
      older = situation(%{id: "40_old", creation_time_ms: @now_ms - 2 * @day_ms})
      newer = situation(%{id: "40_new", creation_time_ms: @now_ms - @hour_ms})

      assert %{current: current} = alerts([fetch([older, newer])])
      assert ids(current) == ["40_new", "40_old"]
    end

    test "orders upcoming alerts by start, the soonest first" do
      later =
        situation(%{
          id: "40_later",
          active_windows: [%{from_ms: @now_ms + 2 * @day_ms, to_ms: nil}]
        })

      sooner =
        situation(%{id: "40_sooner", active_windows: [%{from_ms: @now_ms + @day_ms, to_ms: nil}]})

      assert %{upcoming: upcoming} = alerts([fetch([later, sooner])])
      assert ids(upcoming) == ["40_sooner", "40_later"]
    end
  end

  describe "alerts/1 routes" do
    test "keeps an alert of a route the filter keeps and leaves out one of another" do
      kept = situation(%{id: "40_kept"})

      other =
        situation(%{
          id: "40_other",
          affects: [%{agency_id: "40", route_id: "40_2LINE", stop_id: nil}]
        })

      assert %{current: current} =
               alerts([fetch([kept, other])], %{kept_route_ids: ["40_100479"]})

      assert ids(current) == ["40_kept"]
    end

    test "keeps nothing under a filter that keeps no route" do
      assert %{current: [], upcoming: [], routes: routes} =
               alerts([fetch([situation(%{})])], %{kept_route_ids: []})

      assert routes == %{}
    end

    test "leaves out an alert that names no route" do
      agency_wide = situation(%{affects: [%{agency_id: "40", route_id: nil, stop_id: nil}]})

      assert %{current: []} = alerts([fetch([agency_wide])])
    end

    test "names the routes an alert affects, the kept ones, by their names or identifiers" do
      affects = [
        %{agency_id: "40", route_id: "40_100479", stop_id: nil},
        %{agency_id: "40", route_id: "40_UNNAMED", stop_id: nil}
      ]

      assert %{current: [alert]} = alerts([fetch([situation(%{affects: affects})])])
      assert alert.route_names == ["1 Line", "40_UNNAMED"]
    end
  end

  describe "alerts/1 situations from several fetches" do
    test "reads a situation that several fetches hold once, as the newest fetch holds it" do
      older = fetch([situation(%{summary: "Older"})], DateTime.add(@now, -60))
      newer = %{fetch([situation(%{summary: "Newer"})]) | id: "1_67655"}

      assert %{current: [alert]} = alerts([older, newer])
      assert alert.summary == "Newer"
    end
  end

  describe "alerts/1 popup lines" do
    test "gives each kept route its current alerts, route-wide with no stop" do
      assert %{routes: routes} = alerts([fetch([situation(%{})])])

      assert routes == %{"40_100479" => [%{id: "40_1", summary: "Detour", stop_ids: []}]}
    end

    test "gives a route the stops an alert names at it" do
      affects = [
        %{agency_id: "40", route_id: "40_532", stop_id: "29_355"},
        %{agency_id: "40", route_id: "40_532", stop_id: "1_67655"}
      ]

      assert %{routes: %{"40_532" => [line]}} = alerts([fetch([situation(%{affects: affects})])])
      assert line.stop_ids == ["1_67655", "29_355"]
    end

    test "gives a route that an alert names both route-wide and at a stop no stop" do
      affects = [
        %{agency_id: "40", route_id: "40_532", stop_id: "29_355"},
        %{agency_id: "40", route_id: "40_532", stop_id: nil}
      ]

      assert %{routes: %{"40_532" => [%{stop_ids: []}]}} =
               alerts([fetch([situation(%{affects: affects})])])
    end

    test "gives no route an upcoming alert" do
      windows = [%{from_ms: @now_ms + @day_ms, to_ms: nil}]

      assert %{upcoming: [_alert], routes: routes} =
               alerts([fetch([situation(%{active_windows: windows})])])

      assert routes == %{}
    end

    test "leaves out the routes the filter does not keep" do
      affects = [
        %{agency_id: "40", route_id: "40_100479", stop_id: nil},
        %{agency_id: "40", route_id: "40_2LINE", stop_id: nil}
      ]

      assert %{routes: routes} =
               alerts([fetch([situation(%{affects: affects})])], %{kept_route_ids: ["40_2LINE"]})

      assert Map.keys(routes) == ["40_2LINE"]
    end
  end

  describe "dom_id/1" do
    test "is the same for the same alert and differs between alerts" do
      assert ServiceAlerts.dom_id("40_1") == ServiceAlerts.dom_id("40_1")
      assert ServiceAlerts.dom_id("40_1") != ServiceAlerts.dom_id("40_2")
    end

    test "holds only characters an element identifier takes" do
      assert ServiceAlerts.dom_id("a b/c\"d") =~ ~r/\A[A-Za-z0-9_-]+\z/
    end
  end
end
