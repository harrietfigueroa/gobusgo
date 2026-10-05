defmodule Gobusgo.OneBusAway.StopViewTest do
  # Starts a view per test, hands it record values built by StopRecords from
  # route paths written here, and observes the view through its readers and
  # its announcements. The rules that decide which stops are held are
  # covered with the state module.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.RoutePathBatch.Records
  alias Gobusgo.OneBusAway.RoutePathBatch.StopRecords
  alias Gobusgo.OneBusAway.StopView

  @moduletag capture_log: true

  @first_request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @second_request_id "0199c4a2-7e1b-7a3f-9d20-000000000002"
  @earlier ~U[2026-10-05 01:00:00Z]
  @later ~U[2026-10-05 02:00:00Z]

  setup context do
    view = Module.concat(__MODULE__, "View#{context.line}")

    start_supervised!(
      {StopView, name: view, pubsub: Gobusgo.PubSub, route_count_max: 2, stop_count_max: 3}
    )

    %{view: view}
  end

  defp stop(id, overrides \\ %{}) do
    Map.merge(
      %{
        id: id,
        name: "Stop " <> id,
        lat: 47.6,
        lon: -122.3,
        code: nil,
        direction: nil,
        location_type: 0,
        parent: nil,
        wheelchair_boarding: "UNKNOWN",
        route_ids: []
      },
      overrides
    )
  end

  defp parsed(overrides) do
    fetch =
      Map.merge(
        %{
          route_id: "40_1",
          request_id: @first_request_id,
          fetched_at: @earlier,
          stops: [stop("a"), stop("b")],
          parent_stops: []
        },
        overrides
      )

    %{
      route_id: fetch.route_id,
      destination: "raw/oba/stops-for-route/dt=2026-10-05/route=#{fetch.route_id}/file.json.gz",
      fetched_at: fetch.fetched_at,
      data_sha256: String.duplicate("ab", 32),
      request_id: fetch.request_id,
      route_path: %{
        route_id: fetch.route_id,
        stop_ids: Enum.map(fetch.stops, & &1.id),
        polylines: [],
        stop_groupings: [],
        stops: fetch.stops,
        parent_stops: fetch.parent_stops
      }
    }
  end

  defp value(overrides \\ %{}), do: StopRecords.build(parsed(overrides)).value

  defp newer(overrides) do
    value(Map.merge(%{request_id: @second_request_id, fetched_at: @later}, overrides))
  end

  describe "readers" do
    test "return nothing before a fetch arrives", %{view: view} do
      assert StopView.current(view) == []
      assert StopView.stop(view, "a") == nil
      assert StopView.stop_count(view) == 0
    end

    test "return nothing for a view that is not running" do
      assert StopView.current(NoSuchStopView) == []
      assert StopView.stop(NoSuchStopView, "a") == nil
      assert StopView.stop_count(NoSuchStopView) == 0
    end

    test "return every stop in identifier order", %{view: view} do
      :ok = StopView.apply_records(view, [value(%{stops: [stop("b"), stop("a")]})])

      assert Enum.map(StopView.current(view), & &1.id) == ["a", "b"]
      assert StopView.stop_count(view) == 2
    end

    test "return a stop with the fetch its values come from", %{view: view} do
      :ok = StopView.apply_records(view, [value(%{stops: [stop("a", %{code: "17"})]})])

      assert StopView.stop(view, "a") == %{
               id: "a",
               request_id: @first_request_id,
               fetched_at: @earlier,
               stop: %{
                 "id" => "a",
                 "name" => "Stop a",
                 "lat" => 47.6,
                 "lon" => -122.3,
                 "code" => "17",
                 "direction" => nil,
                 "locationType" => 0,
                 "parent" => nil,
                 "wheelchairBoarding" => "UNKNOWN",
                 "routeIds" => []
               }
             }
    end

    test "return the identifier of every stop in identifier order", %{view: view} do
      :ok = StopView.apply_records(view, [value(%{stops: [stop("b"), stop("a")]})])

      assert StopView.stop_ids(view) == ["a", "b"]
      assert StopView.stop_ids(NoSuchStopView) == []
    end

    test "return a parent stop like any stop", %{view: view} do
      fetch = %{stops: [stop("a", %{parent: "station"})], parent_stops: [stop("station")]}

      :ok = StopView.apply_records(view, [value(fetch)])

      assert %{id: "station"} = StopView.stop(view, "station")
    end
  end

  describe "apply_records/2" do
    test "replaces a stop with the one of a newer fetch", %{view: view} do
      :ok = StopView.apply_records(view, [value()])
      :ok = StopView.apply_records(view, [newer(%{stops: [stop("a", %{name: "Renamed"})]})])

      assert %{request_id: @second_request_id, stop: %{"name" => "Renamed"}} =
               StopView.stop(view, "a")
    end

    test "removes a stop the route's newer fetch does not list", %{view: view} do
      :ok = StopView.apply_records(view, [value()])
      :ok = StopView.apply_records(view, [newer(%{stops: [stop("a")]})])

      assert StopView.stop(view, "b") == nil
      assert StopView.stop_count(view) == 1
    end

    test "keeps a stop another route still lists", %{view: view} do
      other = value(%{route_id: "40_2", stops: [stop("b")]})

      :ok = StopView.apply_records(view, [value(), other, newer(%{stops: [stop("a")]})])

      assert %{id: "b"} = StopView.stop(view, "b")
    end

    test "keeps the current stops when an older fetch arrives", %{view: view} do
      :ok = StopView.apply_records(view, [newer(%{}), value(%{stops: [stop("c")]})])

      assert Enum.map(StopView.current(view), & &1.id) == ["a", "b"]
    end

    test "refuses a fetch beyond the stop bound and logs the count once", %{view: view} do
      over = value(%{route_id: "40_2", stops: [stop("c"), stop("d")]})

      log = capture_log(fn -> :ok = StopView.apply_records(view, [value(), over]) end)

      assert log =~ "Stop view refused fetches beyond its stop bound"
      assert Enum.map(StopView.current(view), & &1.id) == ["a", "b"]
    end

    test "passes over a record of another type without a log line", %{view: view} do
      path = Records.build(parsed(%{})).value

      log = capture_log(fn -> :ok = StopView.apply_records(view, [path, value()]) end)

      refute log =~ "Stop view skipped invalid records"
      assert StopView.stop_count(view) == 2
    end

    test "skips a value that is not a record and logs the count once", %{view: view} do
      log =
        capture_log(fn ->
          :ok = StopView.apply_records(view, ["{", JSON.encode!(%{"other" => 1}), value()])
        end)

      assert log =~ "Stop view skipped invalid records"
      assert StopView.stop_count(view) == 2
    end

    test "raises for more values than a publisher call holds", %{view: view} do
      values = List.duplicate(value(), Gobusgo.Publisher.record_count_max() + 1)

      assert_raise AssertionError, ~r/at most/, fn -> StopView.apply_records(view, values) end
    end
  end

  describe "announcements" do
    setup %{view: view} do
      :ok = StopView.subscribe(%{view: view, pubsub: Gobusgo.PubSub})
    end

    test "one arrives for a call that applies several fetches", %{view: view} do
      :ok = StopView.apply_records(view, [value(), value(%{route_id: "40_2"})])

      assert_received {:stop_view_switched, ^view, _change}
      refute_received {:stop_view_switched, ^view, _change}
    end

    test "arrives after the table holds the stops", %{view: view} do
      :ok = StopView.apply_records(view, [value()])

      assert_received {:stop_view_switched, ^view, _change}
      assert %{id: "a"} = StopView.stop(view, "a")
    end

    test "arrives for a call that only removes a stop", %{view: view} do
      :ok = StopView.apply_records(view, [value(%{stops: [stop("a")]})])
      assert_received {:stop_view_switched, ^view, _change}

      :ok = StopView.apply_records(view, [newer(%{stops: []})])

      assert_received {:stop_view_switched, ^view, _change}
      assert StopView.stop_count(view) == 0
    end

    test "names the stops the call held and the stops it removed", %{view: view} do
      :ok = StopView.apply_records(view, [value(%{stops: [stop("b"), stop("a")]})])
      assert_received {:stop_view_switched, ^view, %{held_ids: ["a", "b"], removed_ids: []}}

      :ok = StopView.apply_records(view, [newer(%{stops: [stop("b"), stop("c")]})])

      assert_received {:stop_view_switched, ^view, %{held_ids: ["b", "c"], removed_ids: ["a"]}}
    end

    test "names a stop once when one call holds it and then removes it", %{view: view} do
      :ok = StopView.apply_records(view, [value(%{stops: [stop("a")]}), newer(%{stops: []})])

      assert_received {:stop_view_switched, ^view, %{held_ids: [], removed_ids: ["a"]}}
    end

    test "names a stop once when one call removes it and then holds it", %{view: view} do
      other = value(%{route_id: "40_2", fetched_at: ~U[2026-10-05 03:00:00Z], stops: [stop("a")]})
      :ok = StopView.apply_records(view, [value(%{stops: [stop("a")]})])
      assert_received {:stop_view_switched, ^view, _change}

      :ok = StopView.apply_records(view, [newer(%{stops: []}), other])

      assert_received {:stop_view_switched, ^view, %{held_ids: ["a"], removed_ids: []}}
    end

    test "none arrives for a call that changes nothing", %{view: view} do
      :ok = StopView.apply_records(view, [value()])
      assert_received {:stop_view_switched, ^view, _change}

      :ok = StopView.apply_records(view, [value(), "{"])

      refute_received {:stop_view_switched, ^view, _change}
    end
  end
end
