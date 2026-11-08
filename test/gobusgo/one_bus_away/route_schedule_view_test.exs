defmodule Gobusgo.OneBusAway.RouteScheduleViewTest do
  # Drives a view started for each test with records RouteScheduleBatch
  # .Records builds from the live fixture, and reads what it holds through
  # its readers, the way a reader of the application's view does.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.OneBusAway.RawRouteScheduleResponse
  alias Gobusgo.OneBusAway.RouteScheduleBatch.Records
  alias Gobusgo.OneBusAway.RouteSchedules
  alias Gobusgo.OneBusAway.RouteScheduleView

  @moduletag capture_log: true

  @fixture_path Path.expand("../../fixtures/one_bus_away/schedule_for_route.json", __DIR__)
  @request_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"

  setup context do
    view = Module.concat(__MODULE__, "View#{context.line}")
    start_supervised!({RouteScheduleView, name: view, route_count_max: 8})
    %{view: view}
  end

  defp value(service_date) do
    envelope = @fixture_path |> File.read!() |> JSON.decode!()
    {:ok, schedule} = RouteSchedules.parse(envelope["data"], "19_41")

    stored =
      RawRouteScheduleResponse.build(%{
        request_id: @request_id,
        response: %{
          route_id: "19_41",
          service_date: service_date,
          schedule: schedule,
          envelope: envelope,
          fetched_at: ~U[2026-11-06 23:15:00Z],
          host: "oba.example.test",
          http_status: 200,
          method: "GET"
        }
      })

    {:ok, parsed} = RawRouteScheduleResponse.parse(stored)
    Records.build(parsed).value
  end

  test "holds a route's schedule on the service date of its record", %{view: view} do
    :ok = RouteScheduleView.apply_records(view, [value(~D[2026-11-07])])

    assert %{id: "19_41", service_date: ~D[2026-11-07], schedule: %{stop_time_count: 64}} =
             RouteScheduleView.schedule(view, "19_41", ~D[2026-11-07])
  end

  test "returns nil for a date it does not hold", %{view: view} do
    :ok = RouteScheduleView.apply_records(view, [value(~D[2026-11-07])])

    assert RouteScheduleView.schedule(view, "19_41", ~D[2026-11-08]) == nil
  end

  test "holds the latest three service dates of a route", %{view: view} do
    values = Enum.map(6..9, &value(Date.new!(2026, 11, &1)))

    :ok = RouteScheduleView.apply_records(view, values)

    assert RouteScheduleView.service_dates(view, "19_41") ==
             [~D[2026-11-07], ~D[2026-11-08], ~D[2026-11-09]]

    assert RouteScheduleView.schedule(view, "19_41", ~D[2026-11-06]) == nil
  end

  test "knows the dates it holds and the dates noted as attempted", %{view: view} do
    :ok = RouteScheduleView.apply_records(view, [value(~D[2026-11-07])])
    :ok = RouteScheduleView.note_attempt(view, %{route_id: "19_41", service_date: ~D[2026-11-08]})
    :ok = RouteScheduleView.note_attempt(view, %{route_id: "1_A", service_date: ~D[2026-11-08]})

    assert RouteScheduleView.known_dates(view) == %{
             "19_41" => [~D[2026-11-07], ~D[2026-11-08]],
             "1_A" => [~D[2026-11-08]]
           }
  end

  test "knows a date once whether it is held, attempted, or both", %{view: view} do
    :ok = RouteScheduleView.apply_records(view, [value(~D[2026-11-07])])
    :ok = RouteScheduleView.note_attempt(view, %{route_id: "19_41", service_date: ~D[2026-11-07]})

    assert RouteScheduleView.known_dates(view) == %{"19_41" => [~D[2026-11-07]]}
  end

  test "counts the routes, schedules, trips, and stop times it holds", %{view: view} do
    :ok = RouteScheduleView.apply_records(view, [value(~D[2026-11-07]), value(~D[2026-11-08])])

    assert RouteScheduleView.counts(view) ==
             %{route_count: 1, schedule_count: 2, trip_count: 4, stop_time_count: 128}
  end

  test "skips a value that is not a record and logs the count", %{view: view} do
    log = capture_log(fn -> :ok = RouteScheduleView.apply_records(view, ["not a record"]) end)

    assert log =~ "Route schedule view skipped invalid records"
    assert RouteScheduleView.counts(view).schedule_count == 0
  end

  test "reads as empty while the view is not running" do
    assert RouteScheduleView.schedule(NotRunning, "19_41", ~D[2026-11-07]) == nil
    assert RouteScheduleView.service_dates(NotRunning, "19_41") == []
    assert RouteScheduleView.known_dates(NotRunning) == %{}

    assert RouteScheduleView.counts(NotRunning) ==
             %{route_count: 0, schedule_count: 0, trip_count: 0, stop_time_count: 0}
  end
end
