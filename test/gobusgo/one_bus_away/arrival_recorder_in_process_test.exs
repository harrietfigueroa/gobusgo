defmodule Gobusgo.OneBusAway.ArrivalRecorderInProcessTest do
  # Runs the arrival recorder through the in-process publisher wired the way
  # the application wires it: the "response stored" event goes to the
  # consumer of its topic, and the consumer's record goes to the arrivals
  # view. A Req.Test stub serves the JSON fixture, the local file backends
  # store and read under a temporary directory, and the view is started for
  # the test with a clock the test sets. What a recorded response leads to
  # is read from the view.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.ArrivalBatch
  alias Gobusgo.OneBusAway.ArrivalRecorder
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RawArrivalResponse
  alias Gobusgo.OneBusAway.ResponseConsumer
  alias Gobusgo.Publisher.InProcess

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @fixture_path Path.expand(
                  "../../fixtures/one_bus_away/arrivals_and_departures_for_stop.json",
                  __DIR__
                )
  @stub_name ArrivalRecorderInProcess
  @gate Module.concat(__MODULE__, Gate)
  @settings %{base_url: "https://oba.example.test", api_key: "test-key-3f9a1c07be52"}
  @fetched_at ~U[2026-10-07 02:19:53Z]
  @fetch_age_ms_max 2_400_000

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

    clock = start_supervised!({Agent, fn -> @fetched_at end})
    view = Module.concat(__MODULE__, "View#{context.line}")

    start_supervised!(
      {FetchView,
       name: view,
       pubsub: Gobusgo.PubSub,
       records: ArrivalBatch.Records,
       id_count_max: 8,
       fetch_age_ms_max: @fetch_age_ms_max,
       clock: fn -> Agent.get(clock, & &1) end}
    )

    process_options = [
      read_options: [base_dir: tmp_dir],
      publish_options: [
        backend: InProcess,
        subscribers: %{"oba.arrivals.state" => {FetchView, :apply_records, [view]}}
      ]
    ]

    event_subscribers = %{
      "oba.arrivals.response-stored" =>
        {ResponseConsumer, :consume,
         [%{event: RawArrivalResponse.StoredEvent, processor: ArrivalBatch}, process_options]}
    }

    options = [
      stop_id: "95_7",
      fetch_options: [
        plug: {Req.Test, @stub_name},
        gate: @gate,
        max_retries: 0,
        clock: fn -> Agent.get(clock, & &1) end
      ],
      write_options: [base_dir: tmp_dir],
      publish_options: [backend: InProcess, subscribers: event_subscribers]
    ]

    %{options: options, view: view, clock: clock}
  end

  test "a recorded response becomes the stop's fetch in the arrivals view", context do
    assert {:ok, %{request_id: request_id, event_published: true}} =
             ArrivalRecorder.record(@settings, context.options)

    assert %{id: "95_7", request_id: ^request_id, fetched_at: @fetched_at, arrivals: arrivals} =
             FetchView.current_fetch(context.view, "95_7")

    assert [
             %{"tripId" => "95_74310062611", "predictedArrivalTimeMs" => nil},
             %{"tripId" => "95_37510062616", "predicted" => false},
             %{"tripId" => "95_73510062616", "vehicleId" => nil},
             %{
               "tripId" => "95_47310062611",
               "predictedArrivalTimeMs" => 1_791_340_620_000,
               "vehicleScheduleDeviationSeconds" => -180
             }
           ] = arrivals
  end

  test "a later recorded response replaces the stop's fetch", context do
    {:ok, %{request_id: first_request_id}} = ArrivalRecorder.record(@settings, context.options)
    Agent.update(context.clock, &DateTime.add(&1, 300, :second))

    {:ok, %{request_id: second_request_id}} = ArrivalRecorder.record(@settings, context.options)

    assert first_request_id != second_request_id

    assert %{request_id: ^second_request_id} = FetchView.current_fetch(context.view, "95_7")
  end

  test "the view drops the stop's fetch once it is older than the view keeps", context do
    {:ok, _recorded} = ArrivalRecorder.record(@settings, context.options)
    Agent.update(context.clock, &DateTime.add(&1, @fetch_age_ms_max + 1, :millisecond))

    :ok = FetchView.apply_records(context.view, [])

    assert FetchView.current_fetch(context.view, "95_7") == nil
  end

  test "a recorded response is stored when no subscriber takes its event", context do
    options =
      Keyword.put(context.options, :publish_options, backend: InProcess, subscribers: %{})

    assert {:ok, %{destination: destination, event_published: false}} =
             ArrivalRecorder.record(@settings, options)

    assert File.exists?(Path.join(context.tmp_dir, destination))
    assert FetchView.current(context.view) == []
  end
end
