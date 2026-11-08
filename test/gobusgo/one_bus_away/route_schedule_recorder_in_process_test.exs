defmodule Gobusgo.OneBusAway.RouteScheduleRecorderInProcessTest do
  # Runs the route schedule recorder through the in-process publisher wired
  # the way the application wires it: the "response stored" event goes to
  # the response consumer, and the processor's record to a schedule view
  # started for the test. A Req.Test stub serves the JSON fixture, and the
  # local file backends store and read under a temporary directory. What a
  # recorded response leads to is read from the view.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.RawRouteScheduleResponse
  alias Gobusgo.OneBusAway.ResponseConsumer
  alias Gobusgo.OneBusAway.RouteScheduleBatch
  alias Gobusgo.OneBusAway.RouteScheduleRecorder
  alias Gobusgo.OneBusAway.RouteScheduleView
  alias Gobusgo.Publisher.InProcess

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @fixture_path Path.expand("../../fixtures/one_bus_away/schedule_for_route.json", __DIR__)
  @stub_name RouteScheduleRecorderInProcess
  @gate Module.concat(__MODULE__, Gate)
  @settings %Gobusgo.Config.OneBusAway{
    base_url: "https://oba.example.test",
    api_key: "test-key-3f9a1c07be52"
  }

  # The requests go through a gate of their own that refills at once, so
  # the tests neither wait on the application's gate nor spend its budget.
  setup do
    start_supervised!({Gobusgo.OneBusAway.RequestGate, name: @gate, refill_interval_ms: 1})
    :ok
  end

  setup %{tmp_dir: tmp_dir} = context do
    Req.Test.stub(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, File.read!(@fixture_path))
    end)

    view = Module.concat(__MODULE__, "View#{context.line}")
    start_supervised!({RouteScheduleView, name: view, route_count_max: 8})

    process_options = [
      read_options: [base_dir: tmp_dir],
      publish_options: [
        backend: InProcess,
        subscribers: %{"oba.schedules.state" => {RouteScheduleView, :apply_records, [view]}}
      ]
    ]

    event_subscribers = %{
      "oba.schedules.response-stored" =>
        {ResponseConsumer, :consume,
         [
           %{event: RawRouteScheduleResponse.StoredEvent, processor: RouteScheduleBatch},
           process_options
         ]}
    }

    options = [
      route_id: "19_41",
      service_date: ~D[2026-11-07],
      fetch_options: [
        plug: {Req.Test, @stub_name},
        gate: @gate,
        max_retries: 0,
        clock: fn -> ~U[2026-11-06 23:15:00Z] end
      ],
      write_options: [base_dir: tmp_dir],
      publish_options: [backend: InProcess, subscribers: event_subscribers]
    ]

    %{options: options, view: view}
  end

  test "a recorded schedule response becomes the route's schedule in the view", context do
    assert {:ok, %{request_id: request_id, event_published: true}} =
             RouteScheduleRecorder.record(@settings, context.options)

    assert %{request_id: ^request_id, schedule: %{stop_time_count: 64}} =
             RouteScheduleView.schedule(context.view, "19_41", ~D[2026-11-07])
  end
end
