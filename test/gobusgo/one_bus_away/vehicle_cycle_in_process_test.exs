defmodule Gobusgo.OneBusAway.VehicleCycleInProcessTest do
  # Runs whole vehicle cycles with the local file backends in a temporary
  # directory and the in-process publisher, so a fetch is followed from the
  # request through the stored file, its "response stored" event, and the
  # processor into a vehicle view of the test's own. Only the HTTP response
  # is a stub.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.ResponseConsumer
  alias Gobusgo.OneBusAway.VehicleCycle
  alias Gobusgo.OneBusAway.VehicleView
  alias Gobusgo.Publisher.InProcess

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @fixture_directory Path.expand("../../fixtures/one_bus_away", __DIR__)
  @stub_name VehicleCycleInProcess
  @gate Module.concat(__MODULE__, Gate)
  @tasks Module.concat(__MODULE__, Tasks)
  @settings %Gobusgo.Config.OneBusAway{
    base_url: "https://oba.example.test",
    api_key: "test-key-3f9a1c07be52"
  }

  # The requests go through a gate of their own that refills at once, so
  # the tests neither wait on the application's gate nor spend its budget.
  setup %{tmp_dir: tmp_dir} = context do
    start_supervised!({Gobusgo.OneBusAway.RequestGate, name: @gate, refill_interval_ms: 1})
    start_supervised!({Task.Supervisor, name: @tasks})
    view = Module.concat(__MODULE__, "View#{context.line}")
    start_supervised!({VehicleView, name: view, pubsub: Gobusgo.PubSub})

    process_options = [
      view: view,
      read_options: [base_dir: tmp_dir],
      publish_options: [
        backend: InProcess,
        subscribers: %{"oba.vehicles-for-agency.state" => {VehicleView, :apply_records, [view]}}
      ]
    ]

    event_subscribers = %{
      "oba.vehicles-for-agency.response-stored" =>
        {ResponseConsumer, :consume,
         [
           %{
             event: Gobusgo.OneBusAway.RawVehicleResponse.StoredEvent,
             processor: Gobusgo.OneBusAway.VehicleBatch
           },
           process_options
         ]}
    }

    %{view: view, event_subscribers: event_subscribers}
  end

  defp stub_fixture(name) do
    body = File.read!(Path.join(@fixture_directory, name <> ".json"))

    Req.Test.stub(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)
  end

  defp run(context, fetched_at) do
    VehicleCycle.run(@settings,
      task_supervisor: @tasks,
      agency_ids: fn -> ["1", "40"] end,
      record_options: [
        fetch_options: [plug: {Req.Test, @stub_name}, gate: @gate, clock: fn -> fetched_at end],
        write_options: [base_dir: context.tmp_dir],
        publish_options: [backend: InProcess, subscribers: context.event_subscribers]
      ]
    )
  end

  defp stored_files(tmp_dir) do
    [tmp_dir, "raw/oba/vehicles-for-agency/**/*.json.gz"]
    |> Path.join()
    |> Path.wildcard()
    |> Enum.map(&Path.relative_to(&1, tmp_dir))
  end

  test "a cycle stores each agency's response compressed and shows its vehicles", context do
    stub_fixture("vehicles_for_agency")

    assert {:ok, %{agency_count: 2, recorded_count: 2, unannounced_count: 0}} =
             run(context, ~U[2026-10-02 03:15:00Z])

    assert [%{agency_id: "1", vehicle_ids: ids}, %{agency_id: "40", vehicle_ids: ids}] =
             VehicleView.current(context.view)

    assert "40_41605" in ids

    assert [
             "raw/oba/vehicles-for-agency/dt=2026-10-02/agency=1/20261002T031500Z_" <> _first,
             "raw/oba/vehicles-for-agency/dt=2026-10-02/agency=40/20261002T031500Z_" <> _second
           ] = files = Enum.sort(stored_files(context.tmp_dir))

    for file <- files do
      assert %{"meta" => %{"agencyId" => _id}} =
               [context.tmp_dir, file]
               |> Path.join()
               |> File.read!()
               |> :zlib.gunzip()
               |> JSON.decode!()
    end
  end

  test "a later cycle without a vehicle drops it from the view", context do
    stub_fixture("vehicles_for_agency")
    assert {:ok, _counts} = run(context, ~U[2026-10-02 03:15:00Z])

    stub_fixture("vehicles_for_agency_empty")
    assert {:ok, _counts} = run(context, ~U[2026-10-02 03:15:05Z])

    assert [
             %{agency_id: "1", fetched_at: ~U[2026-10-02 03:15:05Z], vehicle_ids: []},
             %{agency_id: "40", fetched_at: ~U[2026-10-02 03:15:05Z], vehicle_ids: []}
           ] = VehicleView.current(context.view)
  end
end
