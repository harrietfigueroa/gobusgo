defmodule GobusgoWeb.VehicleLiveServiceAlertsTest do
  # Mounts the vehicle page with Phoenix.LiveViewTest over a basemap manifest
  # the test writes to its temporary directory and the application's two
  # situation views, filled with the record values their records modules
  # build. Both are global state, hence the non-async case. The arrivals'
  # situation view drops a fetch by the real clock, so the fetches are made
  # at the time the test runs, and the alerts' windows are set around it.
  # The browser opens the panel and draws the popups, so these tests observe
  # what the page renders: the Alerts tab, the panel's entries, and the routes'
  # alerts the popups read.
  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Gobusgo.OneBusAway.ArrivalBatch
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.VehicleBatch
  alias GobusgoWeb.ServiceAlerts

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @endpoint GobusgoWeb.Endpoint
  @vehicle_situation_view Gobusgo.OneBusAway.VehicleSituationView
  @arrival_situation_view Gobusgo.OneBusAway.ArrivalSituationView
  @route_view Gobusgo.OneBusAway.RouteView
  @day_ms 24 * 60 * 60 * 1_000
  @bounds %{"south" => 47.0, "west" => -123.0, "north" => 48.0, "east" => -122.0}
  @manifest %{
    "snapshot" => "20261004",
    "archives" => [%{"name" => "basemap-20261004-01.pmtiles", "bounds" => @bounds}],
    "agencies" => [
      %{"agencyId" => "40", "archive" => "basemap-20261004-01.pmtiles", "bounds" => @bounds}
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
    for view <- [@vehicle_situation_view, @arrival_situation_view, @route_view] do
      :ok = Supervisor.terminate_child(Gobusgo.Supervisor, view)
      {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, view)
    end
  end

  defp request_id(sequence) do
    "0199c4a2-7e1b-7a3f-9d20-" <> String.pad_leading(Integer.to_string(sequence), 12, "0")
  end

  defp situation(overrides) do
    Map.merge(
      %{
        id: "40_21008",
        summary: "Link shuttle buses replace 2 Line trains.",
        description: "Plan ahead.\nUse the 1 Line.",
        url: "https://www.soundtransit.org/planned-service-disruptions",
        reason: "MAINTENANCE",
        creation_time_ms: 1_792_080_593_599,
        active_windows: [],
        affects: [%{agency_id: "40", route_id: "40_2LINE", stop_id: nil}]
      },
      overrides
    )
  end

  defp fetch(id, situations, now, sequence) do
    %{
      request_id: request_id(sequence),
      fetched_at: now,
      data_sha256: String.duplicate("ab", 32),
      destination: "raw/oba/example/dt=2026-10-15/file.json.gz",
      situations: situations
    }
    |> Map.put(:agency_id, id)
    |> Map.put(:stop_id, id)
  end

  defp apply_vehicle_situations(situations, now, sequence \\ 1) do
    record = VehicleBatch.SituationRecords.build(fetch("40", situations, now, sequence))
    :ok = FetchView.apply_records(@vehicle_situation_view, [record.value])
  end

  defp apply_arrival_situations(stop_id, situations, now) do
    record = ArrivalBatch.SituationRecords.build(fetch(stop_id, situations, now, 2))
    :ok = FetchView.apply_records(@arrival_situation_view, [record.value])
  end

  # Publishes the routes of agency 40: the 2 Line, named, and the 1 Line.
  defp apply_routes(now) do
    routes =
      for {id, short_name} <- [{"40_2LINE", "2 Line"}, {"40_100479", "1 Line"}] do
        %{
          id: id,
          agency_id: "40",
          short_name: short_name,
          long_name: nil,
          description: nil,
          type: 0,
          color: nil,
          text_color: nil,
          url: nil
        }
      end

    record =
      RouteBatch.Records.build(%{
        agency_id: "40",
        request_id: request_id(3),
        fetched_at: now,
        data_sha256: String.duplicate("ab", 32),
        destination: "raw/oba/routes-for-agency/dt=2026-10-15/agency=40/file.json.gz",
        routes: routes
      })

    :ok = FetchView.apply_records(@route_view, [record.value])
  end

  defp routes(view) do
    [value] =
      view
      |> element("#service-alert-routes")
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.attribute("data-routes")

    JSON.decode!(value)
  end

  describe "GET /vehicles with no alert" do
    test "counts no alert on the Alerts tab and gives the popups no alert", %{now: _now} do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      refute has_element?(view, "#panel-tab-alerts-badge")
      assert has_element?(view, "#service-alerts-current", "No alerts now.")
      assert routes(view) == %{}
    end
  end

  describe "GET /vehicles with a current alert" do
    setup %{now: now} do
      apply_routes(now)
      apply_vehicle_situations([situation(%{})], now)
      :ok
    end

    test "counts the current alerts on the Alerts tab" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert view |> element("#panel-tab-alerts-badge") |> render() =~ "1"
      assert has_element?(view, "#panel-tab-alerts[aria-label='Alerts, 1 now']")
    end

    test "lists the alert with its summary, routes, description, and link" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      entry = view |> element("#service-alerts-current ##{ServiceAlerts.dom_id("40_21008")}")

      html = render(entry)
      assert html =~ "Link shuttle buses replace 2 Line trains."
      assert html =~ "Route: 2 Line"
      assert html =~ "Plan ahead."
      assert html =~ ~s(href="https://www.soundtransit.org/planned-service-disruptions")
      assert html =~ ~s(data-alert-id="40_21008")
    end

    test "names the alert by its summary, and describes its Details and its link with it" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      dom_id = ServiceAlerts.dom_id("40_21008")
      summary_id = dom_id <> "-summary"
      entry = "#service-alerts-current ##{dom_id}"

      assert has_element?(view, "##{summary_id}", "Link shuttle buses replace 2 Line trains.")
      assert has_element?(view, "#{entry}[aria-labelledby='#{summary_id}']")
      assert has_element?(view, "#{entry} summary[aria-describedby='#{summary_id}']")
      assert has_element?(view, "#{entry} a[aria-describedby='#{summary_id}']")
    end

    test "gives the popups of the alert's route the alert, route-wide" do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert routes(view) == %{
               "40_2LINE" => [
                 %{
                   "id" => "40_21008",
                   "summary" => "Link shuttle buses replace 2 Line trains.",
                   "stop_ids" => []
                 }
               ]
             }
    end

    test "leaves the alert out under a filter that keeps another route" do
      {:ok, view, _html} = live(build_conn(), "/vehicles?route=40_100479")

      refute has_element?(view, "#panel-tab-alerts-badge")
      assert routes(view) == %{}
    end

    test "keeps the alert under a filter that keeps its route" do
      {:ok, view, _html} = live(build_conn(), "/vehicles?route=40_2LINE")

      assert has_element?(view, "#panel-tab-alerts-badge")
    end
  end

  describe "GET /vehicles with an upcoming alert" do
    test "lists it with its start and counts no alert now", %{now: now} do
      starts_ms = DateTime.to_unix(now, :millisecond) + @day_ms

      apply_vehicle_situations(
        [situation(%{active_windows: [%{from_ms: starts_ms, to_ms: nil}]})],
        now
      )

      {:ok, view, _html} = live(build_conn(), "/vehicles")

      assert has_element?(view, "#panel-tab-alerts[aria-label='Alerts']")
      refute has_element?(view, "#panel-tab-alerts-badge")

      time = DateTime.from_unix!(starts_ms, :millisecond) |> DateTime.to_iso8601()
      assert has_element?(view, "#service-alerts-upcoming time[datetime='#{time}']")
      assert routes(view) == %{}
    end
  end

  describe "a connected page" do
    test "shows an alert that the vehicle situations bring after it mounts", %{now: now} do
      {:ok, view, _html} = live(build_conn(), "/vehicles")
      refute has_element?(view, "#panel-tab-alerts-badge")

      apply_vehicle_situations([situation(%{})], now)

      assert has_element?(view, "#panel-tab-alerts-badge")
    end

    test "drops an alert that the next vehicle fetch no longer references", %{now: now} do
      apply_vehicle_situations([situation(%{})], now)
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      apply_vehicle_situations([], DateTime.add(now, 10), 2)

      refute has_element?(view, "#panel-tab-alerts-badge")
    end

    test "gives a stop's popups the alert its arrivals bring, at that stop", %{now: now} do
      {:ok, view, _html} = live(build_conn(), "/vehicles")

      affects = [%{agency_id: "40", route_id: "40_532", stop_id: "1_67655"}]
      apply_arrival_situations("1_67655", [situation(%{id: "29_74873", affects: affects})], now)

      assert %{"40_532" => [%{"id" => "29_74873", "stop_ids" => ["1_67655"]}]} = routes(view)
    end
  end
end
