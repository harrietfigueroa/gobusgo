defmodule GobusgoWeb.VehicleLiveStopArrivalsTest do
  # Mounts the vehicle page with Phoenix.LiveViewTest over a basemap manifest
  # the test writes to its temporary directory and the application's stop
  # view, arrivals view, vehicle view, and demand registry, filled
  # with the record values their records modules build. All are global
  # state, hence the non-async case. The arrivals view drops a fetch by the
  # real clock, so the fetches are made at the time the test runs, and each
  # arrival stands half a minute inside its minute so that the seconds a
  # test takes do not move it. The browser shows the arrivals, so these
  # tests observe what the page hands it: the events that carry a stop's
  # arrivals, and the stops the registry holds as open.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.Demand
  alias Gobusgo.OneBusAway.ArrivalBatch
  alias Gobusgo.OneBusAway.DemandKey
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RoutePathBatch.StopRecords
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.OneBusAway.VehicleBatch
  alias Gobusgo.OneBusAway.VehicleView
  alias GobusgoWeb.VehicleLive.OpenStops

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @event "stop-arrivals:arrivals"
  @push_wait_ms 50
  @registration_check_interval_ms 20
  @registration_check_count_max 250
  @arrival_view Gobusgo.OneBusAway.ArrivalView
  @stop_id "1_1471"
  @trip_id "1_800582101"
  @vehicle_id "1_4342"
  @bounds %{"south" => 47.0, "west" => -123.0, "north" => 48.0, "east" => -122.0}
  @manifest %{
    "snapshot" => "20261004",
    "archives" => [%{"name" => "basemap-20261004-01.pmtiles", "bounds" => @bounds}],
    "agencies" => [
      %{"agencyId" => "1", "archive" => "basemap-20261004-01.pmtiles", "bounds" => @bounds}
    ]
  }

  setup %{tmp_dir: tmp_dir} do
    configured = Application.fetch_env!(:gobusgo, :basemap)
    Application.put_env(:gobusgo, :basemap, dir: tmp_dir)
    File.write!(Path.join(tmp_dir, "manifest.json"), JSON.encode!(@manifest))
    restart_views()

    on_exit(fn ->
      Application.put_env(:gobusgo, :basemap, configured)
      restart_views()
    end)

    %{now: DateTime.truncate(DateTime.utc_now(), :second)}
  end

  defp restart_views do
    for view <- [VehicleView, StopView, @arrival_view] do
      :ok = Supervisor.terminate_child(Gobusgo.Supervisor, view)
      {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, view)
    end
  end

  defp request_id(sequence) do
    "0199c4a2-7e1b-7a3f-9d20-" <> String.pad_leading(Integer.to_string(sequence), 12, "0")
  end

  # Publishes a fetch of the stops of one route, which lists `stop_ids`.
  defp apply_stops(stop_ids, now) do
    stops =
      for id <- stop_ids do
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
          route_ids: ["1_100210"]
        }
      end

    record =
      StopRecords.build(%{
        route_id: "1_100210",
        destination: "raw/oba/stops-for-route/dt=2026-10-07/route=1_100210/file.json.gz",
        fetched_at: now,
        data_sha256: String.duplicate("ab", 32),
        request_id: request_id(0),
        route_path: %{
          route_id: "1_100210",
          stop_ids: stop_ids,
          polylines: [],
          stop_groupings: [],
          stops: stops,
          parent_stops: []
        }
      })

    :ok = StopView.apply_records(StopView, [record.value])
  end

  # An arrival predicted `minutes` and a half from `now`, two minutes later
  # than its schedule, by a vehicle that was two minutes late at the fetch.
  defp arrival(now, minutes, fields \\ %{}) do
    predicted_ms = DateTime.to_unix(now, :millisecond) + minutes * 60_000 + 30_000

    Map.merge(
      %{
        trip_id: @trip_id,
        service_date_ms: 1_791_270_000_000,
        stop_sequence: 5,
        route_id: "1_100210",
        route_short_name: "36",
        route_long_name: nil,
        trip_headsign: "Othello Station",
        arrival_enabled: true,
        departure_enabled: true,
        scheduled_arrival_time_ms: predicted_ms - 120_000,
        scheduled_departure_time_ms: predicted_ms - 120_000,
        predicted: true,
        predicted_arrival_time_ms: predicted_ms,
        predicted_departure_time_ms: predicted_ms,
        vehicle_id: @vehicle_id,
        vehicle_schedule_deviation_seconds: 120
      },
      fields
    )
  end

  # Publishes a fetch of the arrivals at `stop_id`; `sequence` orders the
  # fetches of a test, as the request identifier and as seconds after `now`.
  defp apply_arrivals(arrivals, %{stop_id: stop_id, now: now, sequence: sequence}) do
    record =
      ArrivalBatch.Records.build(%{
        stop_id: stop_id,
        destination:
          "raw/oba/arrivals-and-departures-for-stop/dt=2026-10-07/stop=#{stop_id}/file.json.gz",
        fetched_at: DateTime.add(now, sequence, :second),
        data_sha256: String.duplicate("ab", 32),
        request_id: request_id(sequence),
        arrivals: arrivals
      })

    :ok = FetchView.apply_records(@arrival_view, [record.value])
  end

  # Publishes a fetch of agency `1` whose one vehicle serves the arrival's
  # trip, `deviation_seconds` from its schedule.
  defp apply_vehicle(deviation_seconds, %{now: now, sequence: sequence}) do
    vehicle = %{
      id: @vehicle_id,
      active_trip_id: @trip_id,
      route_id: "1_100210",
      route_short_name: "36",
      route_long_name: nil,
      trip_headsign: "Othello Station",
      position: %{lat: 47.6, lon: -122.3},
      orientation: nil,
      last_known_location: nil,
      last_known_orientation: nil,
      last_update_time_ms: nil,
      last_location_update_time_ms: DateTime.to_unix(now, :millisecond),
      predicted: true,
      schedule_deviation_seconds: deviation_seconds,
      next_stop_id: nil,
      next_stop_time_offset_seconds: nil
    }

    %{vehicles: records, manifest: manifest} =
      VehicleBatch.Records.build(%{
        agency_id: "1",
        destination: "raw/oba/vehicles-for-agency/dt=2026-10-07/agency=1/file.json.gz",
        fetched_at: DateTime.add(now, sequence, :second),
        data_sha256: String.duplicate("ab", 32),
        request_id: request_id(sequence),
        vehicles: [vehicle]
      })

    :ok = VehicleView.apply_records(VehicleView, Enum.map(records ++ [manifest], & &1.value))
  end

  defp open_stop_ids, do: Demand.items(Demand, DemandKey.arrivals_dataset())

  # Reads the open stops until they are `expected`, for the page registers
  # in its own time after the registry is back, and gives up after
  # @registration_check_count_max reads.
  defp await_open_stop_ids(expected, checks_left \\ @registration_check_count_max) do
    case open_stop_ids() do
      ^expected ->
        :ok

      stop_ids when checks_left > 1 ->
        assert is_list(stop_ids)
        Process.sleep(@registration_check_interval_ms)
        await_open_stop_ids(expected, checks_left - 1)

      stop_ids ->
        flunk("expected the open stops #{inspect(expected)}, got: #{inspect(stop_ids)}")
    end
  end

  defp open_page do
    {:ok, view, _html} = live(build_conn(), "/vehicles")
    view
  end

  defp hook(view, event, params),
    do: view |> element("#stop-markers") |> render_hook(event, params)

  defp open_stop(view, stop_id \\ @stop_id),
    do: hook(view, "stop-arrivals:open", %{"stop_id" => stop_id})

  defp close_stop(view, stop_id \\ @stop_id),
    do: hook(view, "stop-arrivals:close", %{"stop_id" => stop_id})

  describe "opening a stop" do
    test "is answered at once with the arrivals the arrivals view holds", %{now: now} do
      apply_stops([@stop_id], now)
      apply_arrivals([arrival(now, 12)], %{stop_id: @stop_id, now: now, sequence: 0})
      view = open_page()

      open_stop(view)

      assert_push_event(view, @event, %{
        stop_id: @stop_id,
        status: :arrivals,
        age_minutes: 0,
        arrivals: [%{route: "36", headsign: "Othello Station", minutes: 12, predicted: true}]
      })
    end

    test "is answered with waiting for a stop that has no fetch, then with its arrivals",
         %{now: now} do
      apply_stops([@stop_id], now)
      view = open_page()

      open_stop(view)

      assert_push_event(view, @event, %{stop_id: @stop_id, status: :waiting})

      apply_arrivals([arrival(now, 7)], %{stop_id: @stop_id, now: now, sequence: 0})

      assert_push_event(view, @event, %{status: :arrivals, arrivals: [%{minutes: 7}]})
    end

    test "registers the stop as open", %{now: now} do
      apply_stops([@stop_id], now)
      view = open_page()

      open_stop(view)

      assert open_stop_ids() == [@stop_id]
    end

    test "is refused for a stop the stop view does not hold, which stays closed", %{now: now} do
      apply_arrivals([arrival(now, 12)], %{stop_id: @stop_id, now: now, sequence: 0})
      view = open_page()

      open_stop(view)

      assert_push_event(view, @event, %{stop_id: @stop_id, status: :refused})
      assert open_stop_ids() == []
    end

    test "is answered with busy beyond the stops one page has open", %{now: now} do
      open_count_max = OpenStops.open_count_max()
      stop_ids = for index <- 1..(open_count_max + 1), do: "1_#{index}"
      apply_stops(stop_ids, now)
      view = open_page()

      for stop_id <- Enum.take(stop_ids, open_count_max) do
        open_stop(view, stop_id)
        assert_push_event(view, @event, %{stop_id: ^stop_id, status: :waiting})
      end

      beyond = List.last(stop_ids)
      open_stop(view, beyond)

      assert_push_event(view, @event, %{stop_id: ^beyond, status: :busy})
      assert Enum.sort(open_stop_ids()) == Enum.sort(Enum.take(stop_ids, open_count_max))
    end

    test "again sends the arrivals again", %{now: now} do
      apply_stops([@stop_id], now)
      apply_arrivals([arrival(now, 12)], %{stop_id: @stop_id, now: now, sequence: 0})
      view = open_page()
      open_stop(view)
      assert_push_event(view, @event, %{status: :arrivals})

      open_stop(view)

      assert_push_event(view, @event, %{status: :arrivals, arrivals: [%{minutes: 12}]})
    end

    test "changes nothing when the event names no stop", %{now: now} do
      apply_stops([@stop_id], now)
      view = open_page()

      hook(view, "stop-arrivals:open", %{})
      hook(view, "stop-arrivals:open", %{"stop_id" => 1471})

      refute_push_event(view, @event, %{}, @push_wait_ms)
      assert open_stop_ids() == []
    end
  end

  describe "an open stop" do
    setup %{now: now} do
      apply_stops([@stop_id], now)
      apply_arrivals([arrival(now, 12)], %{stop_id: @stop_id, now: now, sequence: 0})
      view = open_page()
      open_stop(view)
      assert_push_event(view, @event, %{status: :arrivals, arrivals: [%{minutes: 12}]})
      %{view: view}
    end

    test "is sent again when the arrivals view switches it", %{view: view, now: now} do
      apply_arrivals([arrival(now, 4)], %{stop_id: @stop_id, now: now, sequence: 1})

      assert_push_event(view, @event, %{stop_id: @stop_id, arrivals: [%{minutes: 4}]})
    end

    test "is not sent again when the arrivals view switches another stop",
         %{view: view, now: now} do
      apply_arrivals([arrival(now, 4)], %{stop_id: "1_999", now: now, sequence: 1})

      refute_push_event(view, @event, %{}, @push_wait_ms)
    end

    test "moves two minutes later when its vehicle is two minutes later than at the fetch",
         %{view: view, now: now} do
      apply_vehicle(240, %{now: now, sequence: 1})

      assert_push_event(view, @event, %{
        stop_id: @stop_id,
        arrivals: [%{minutes: 14, predicted: true}]
      })
    end

    test "is registered again with a registry that restarts", %{view: _view} do
      :ok = Supervisor.terminate_child(Gobusgo.Supervisor, Demand)
      {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, Demand)

      await_open_stop_ids([@stop_id])
    end

    test "is not sent again when its vehicle is as late as at the fetch",
         %{view: view, now: now} do
      apply_vehicle(120, %{now: now, sequence: 1})

      refute_push_event(view, @event, %{}, @push_wait_ms)
    end
  end

  describe "closing" do
    setup %{now: now} do
      apply_stops([@stop_id], now)
      view = open_page()
      open_stop(view)
      assert_push_event(view, @event, %{status: :waiting})
      %{view: view}
    end

    test "a stop ends its registration", %{view: view} do
      close_stop(view)

      assert open_stop_ids() == []
    end

    test "a stop ends its arrivals", %{view: view, now: now} do
      close_stop(view)

      apply_arrivals([arrival(now, 4)], %{stop_id: @stop_id, now: now, sequence: 1})

      refute_push_event(view, @event, %{}, @push_wait_ms)
    end

    test "a stop that is not open changes nothing", %{view: view} do
      close_stop(view, "1_999")

      assert open_stop_ids() == [@stop_id]
    end

    test "the page ends the registration of every stop it had open", %{view: view} do
      reference = Process.monitor(view.pid)
      Process.exit(view.pid, :kill)
      assert_receive {:DOWN, ^reference, :process, _pid, _reason}

      assert open_stop_ids() == []
    end
  end
end
