defmodule Gobusgo.OneBusAway.RouteScheduleRebuildTest do
  # Stores schedule responses through the writer in a temporary directory,
  # the form the recorder writes, runs a rebuild against a schedule view
  # started for the test, and observes what the view holds and what the run
  # returns and logs. The log cases read a whole capture, hence the
  # non-async case.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Gobusgo.OneBusAway.RawRouteScheduleResponse
  alias Gobusgo.OneBusAway.RouteScheduleRebuild
  alias Gobusgo.OneBusAway.RouteSchedules
  alias Gobusgo.OneBusAway.RouteScheduleView
  alias Gobusgo.Publisher.InProcess
  alias Gobusgo.Writer

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @fixture_path Path.expand("../../fixtures/one_bus_away/schedule_for_route.json", __DIR__)
  @route_id "19_41"
  @now ~U[2026-11-07 12:00:00Z]

  defmodule FailingDiscovery do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(_destination, _options), do: {:error, :not_found}

    @impl Gobusgo.Reader
    def discover(_request, _options), do: {:error, :io_failure}
  end

  defmodule SlowReader do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(_destination, _options), do: {:error, :not_found}

    @impl Gobusgo.Reader
    def discover(_request, _options), do: Process.sleep(:infinity)
  end

  setup context do
    view = Module.concat(__MODULE__, "View#{context.line}")
    start_supervised!({RouteScheduleView, name: view, route_count_max: 8})

    options = [
      now: fn -> @now end,
      read_options: [base_dir: context.tmp_dir],
      publish_options: [
        backend: InProcess,
        subscribers: %{"oba.schedules.state" => {RouteScheduleView, :apply_records, [view]}}
      ]
    ]

    %{view: view, options: options}
  end

  defp request_id(index) do
    "0199c4a2-7e1b-7a3f-9d20-" <> String.pad_leading(Integer.to_string(index), 12, "0")
  end

  defp store(context, %{service_date: service_date, fetched_at: fetched_at, index: index}) do
    envelope = @fixture_path |> File.read!() |> JSON.decode!()
    {:ok, schedule} = RouteSchedules.parse(envelope["data"], @route_id)

    stored =
      RawRouteScheduleResponse.build(%{
        request_id: request_id(index),
        response: %{
          route_id: @route_id,
          service_date: service_date,
          schedule: schedule,
          envelope: envelope,
          fetched_at: fetched_at,
          host: "oba.example.test",
          http_status: 200,
          method: "GET"
        }
      })

    :ok = Writer.write(Map.take(stored, [:destination, :content]), base_dir: context.tmp_dir)
    stored
  end

  test "fills the view with the dates before, of, and after the UTC date", context do
    for {service_date, fetched_at, index} <- [
          {~D[2026-11-06], ~U[2026-11-05 10:00:00Z], 1},
          {~D[2026-11-07], ~U[2026-11-06 10:00:00Z], 2},
          {~D[2026-11-08], ~U[2026-11-07 10:00:00Z], 3}
        ] do
      store(context, %{service_date: service_date, fetched_at: fetched_at, index: index})
    end

    assert RouteScheduleRebuild.run(context.options) ==
             %{processed_count: 3, failed_count: 0, undiscovered_day_count: 0}

    assert RouteScheduleView.service_dates(context.view, @route_id) ==
             [~D[2026-11-06], ~D[2026-11-07], ~D[2026-11-08]]
  end

  test "leaves out a service date the view does not want today", context do
    store(context, %{service_date: ~D[2026-11-05], fetched_at: ~U[2026-11-05 10:00:00Z], index: 1})

    assert %{processed_count: 0} = RouteScheduleRebuild.run(context.options)
    assert RouteScheduleView.service_dates(context.view, @route_id) == []
  end

  test "processes the newest response of a route and date", context do
    store(context, %{service_date: ~D[2026-11-08], fetched_at: ~U[2026-11-06 10:00:00Z], index: 1})

    store(context, %{
      service_date: ~D[2026-11-08],
      fetched_at: ~U[2026-11-07 10:00:00Z],
      index: 2
    })

    assert %{processed_count: 1} = RouteScheduleRebuild.run(context.options)

    assert %{request_id: request_id} =
             RouteScheduleView.schedule(context.view, @route_id, ~D[2026-11-08])

    assert request_id == request_id(2)
  end

  test "counts each fetch date whose discovery fails and logs the run incomplete", context do
    options = Keyword.put(context.options, :read_options, backend: FailingDiscovery)

    log =
      capture_log(fn ->
        assert %{undiscovered_day_count: 3} = RouteScheduleRebuild.run(options)
      end)

    assert log =~ "Route schedule view rebuilt incomplete"
  end

  test "logs a complete run at info", context do
    log = capture_log(fn -> RouteScheduleRebuild.run(context.options) end)

    assert log =~ "[info] Route schedule view rebuilt"
  end

  test "start_link/1 returns :ignore once the deadline passes", context do
    start_supervised!({Task.Supervisor, name: __MODULE__.Tasks})
    options = Keyword.put(context.options, :read_options, backend: SlowReader)

    log =
      capture_log(fn ->
        assert RouteScheduleRebuild.start_link(
                 [task_supervisor: __MODULE__.Tasks, deadline_ms: 50] ++ options
               ) == :ignore
      end)

    assert log =~ "Route schedule view rebuild stopped"
  end
end
