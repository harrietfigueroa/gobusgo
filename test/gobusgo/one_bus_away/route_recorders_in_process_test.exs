defmodule Gobusgo.OneBusAway.RouteRecordersInProcessTest do
  # Runs both route recorders through the in-process publisher wired the way
  # the application wires it: each "response stored" event goes to the one
  # consumer of the shared topic, and the consumer's records go to both
  # views. Req.Test stubs serve the JSON fixtures, the local file backends
  # store and read under a temporary directory, and the views are started
  # for the test. What a recorded response leads to is read from its view.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.ResponseConsumer
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RouteDatasets
  alias Gobusgo.OneBusAway.RoutePathBatch
  alias Gobusgo.OneBusAway.RoutePathRecorder
  alias Gobusgo.OneBusAway.RouteRecorder
  alias Gobusgo.Publisher.InProcess

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @fixture_directory Path.expand("../../fixtures/one_bus_away", __DIR__)
  @stub_name RouteRecordersInProcess
  @gate Module.concat(__MODULE__, Gate)
  @settings %{base_url: "https://oba.example.test", api_key: "test-key-3f9a1c07be52"}

  # The requests go through a gate of their own that refills at once, so
  # the tests neither wait on the application's gate nor spend its budget.
  setup do
    start_supervised!({Gobusgo.OneBusAway.RequestGate, name: @gate, refill_interval_ms: 1})
    :ok
  end

  setup %{tmp_dir: tmp_dir} = context do
    Req.Test.stub(@stub_name, fn conn ->
      fixture =
        case conn.request_path do
          "/api/where/routes-for-agency/" <> _agency -> "routes_for_agency"
          "/api/where/stops-for-route/" <> _route -> "stops_for_route"
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, File.read!(Path.join(@fixture_directory, fixture <> ".json")))
    end)

    route_view = Module.concat(__MODULE__, "RouteView#{context.line}")
    route_path_view = Module.concat(__MODULE__, "RoutePathView#{context.line}")

    for {view, records} <- [
          {route_view, RouteBatch.Records},
          {route_path_view, RoutePathBatch.Records}
        ] do
      start_supervised!(
        {FetchView, name: view, pubsub: Gobusgo.PubSub, records: records, id_count_max: 8}
      )
    end

    state_subscribers = %{
      "oba.routes.state" => {FetchView, :apply_records_to_each, [[route_view, route_path_view]]}
    }

    process_options = [
      read_options: [base_dir: tmp_dir],
      publish_options: [backend: InProcess, subscribers: state_subscribers]
    ]

    event_subscribers = %{
      "oba.routes.response-stored" =>
        {ResponseConsumer, :consume,
         [%{event: RouteDatasets, processor: RouteDatasets}, process_options]}
    }

    options = [
      fetch_options: [
        plug: {Req.Test, @stub_name},
        gate: @gate,
        max_retries: 0,
        clock: fn -> ~U[2026-10-05 01:17:31Z] end
      ],
      write_options: [base_dir: tmp_dir],
      publish_options: [backend: InProcess, subscribers: event_subscribers]
    ]

    %{options: options, route_view: route_view, route_path_view: route_path_view}
  end

  test "a recorded routes response becomes the agency's fetch in the route view", context do
    options = Keyword.put(context.options, :agency_id, "40")

    assert {:ok, %{request_id: request_id, event_published: true}} =
             RouteRecorder.record(@settings, options)

    assert [%{id: "40", request_id: ^request_id, route_ids: route_ids}] =
             FetchView.current(context.route_view)

    assert route_ids == ["40_100479", "40_100511", "40_SNDR_EV"]
    assert FetchView.current(context.route_path_view) == []
  end

  test "a recorded route path response becomes the route's fetch in the path view", context do
    options = Keyword.put(context.options, :route_id, "1_100336")

    assert {:ok, %{request_id: request_id, event_published: true}} =
             RoutePathRecorder.record(@settings, options)

    assert %{request_id: ^request_id, polylines: [%{"points" => "mbpaHphuiVJVbhAn|F"}]} =
             FetchView.current_fetch(context.route_path_view, "1_100336")

    assert FetchView.current(context.route_view) == []
  end

  test "a recorded response is stored when no subscriber takes its event", context do
    options =
      context.options
      |> Keyword.put(:agency_id, "40")
      |> Keyword.put(:publish_options, backend: InProcess, subscribers: %{})

    assert {:ok, %{destination: destination, event_published: false}} =
             RouteRecorder.record(@settings, options)

    assert File.exists?(Path.join(context.tmp_dir, destination))
    assert FetchView.current(context.route_view) == []
  end
end
