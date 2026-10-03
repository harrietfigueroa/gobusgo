defmodule Gobusgo.OneBusAway.AgencyRecorderInProcessTest do
  # Runs record/2 through the in-process publisher wired the way the
  # application wires it: the "response stored" event goes to the consumer,
  # the consumer's records go to a view. A Req.Test stub serves the JSON
  # fixture, the local file backends store and read under a temporary
  # directory, and the view is one started for the test. What a recorded
  # response leads to is read from the view, the way a request reads it.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.AgencyBatch.Consumer
  alias Gobusgo.OneBusAway.AgencyRecorder
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.Publisher.InProcess

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @fixture_path Path.expand("../../fixtures/one_bus_away/agencies_with_coverage.json", __DIR__)
  @stub_name AgencyRecorderInProcess
  @gate Module.concat(__MODULE__, Gate)
  @settings %{base_url: "https://oba.example.test", api_key: "test-key-3f9a1c07be52"}
  @request_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"

  # The requests go through a gate of their own that refills at once, so
  # the tests neither wait on the application's gate nor spend its budget.
  setup do
    start_supervised!({Gobusgo.OneBusAway.RequestGate, name: @gate, refill_interval_ms: 1})
    :ok
  end

  setup %{tmp_dir: tmp_dir} = context do
    body = File.read!(@fixture_path)

    Req.Test.stub(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)

    view = Module.concat(__MODULE__, "View#{context.line}")
    start_supervised!({AgencyView, name: view, pubsub: Gobusgo.PubSub})

    state_subscribers = %{
      "oba.agencies-with-coverage.state" => {AgencyView, :apply_records, [view]}
    }

    process_options = [
      read_options: [base_dir: tmp_dir],
      publish_options: [backend: InProcess, subscribers: state_subscribers]
    ]

    event_subscribers = %{
      "oba.agencies-with-coverage.response-stored" => {Consumer, :consume, [process_options]}
    }

    options = [
      request_id: @request_id,
      fetch_options: [
        plug: {Req.Test, @stub_name},
        gate: @gate,
        max_retries: 0,
        clock: fn -> ~U[2026-10-02 03:15:00Z] end
      ],
      write_options: [base_dir: tmp_dir],
      publish_options: [backend: InProcess, subscribers: event_subscribers]
    ]

    %{options: options, view: view}
  end

  test "a recorded response becomes the view's current fetch", %{options: options, view: view} do
    assert AgencyView.current(view) == nil

    assert {:ok, %{fetched_at: fetched_at}} = AgencyRecorder.record(@settings, options)

    assert %{request_id: @request_id, fetched_at: ^fetched_at, agency_ids: ["1", "40"]} =
             AgencyView.current(view)
  end

  test "a recorded response is stored when no subscriber takes its event", %{
    tmp_dir: tmp_dir,
    options: options,
    view: view
  } do
    options = Keyword.put(options, :publish_options, backend: InProcess, subscribers: %{})

    assert {:ok, %{destination: destination}} = AgencyRecorder.record(@settings, options)

    assert File.exists?(Path.join(tmp_dir, destination))
    assert AgencyView.current(view) == nil
  end
end
