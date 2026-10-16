defmodule Gobusgo.OneBusAway.SourcesTest do
  # Reads the source specs as values, and calls each source's run with a
  # Req.Test stub serving a JSON fixture and writer and publisher doubles
  # defined here, so the run is observed through the writer contract with no
  # network access, no storage, and no subscriber. The vehicle source's
  # signals come from a demand registry of the test's own, on a clock the
  # test advances.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.Cadence
  alias Gobusgo.Demand
  alias Gobusgo.OneBusAway.ArrivalBatch
  alias Gobusgo.OneBusAway.DemandKey
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.Sources
  alias Gobusgo.OneBusAway.VehicleView
  alias Gobusgo.Scheduler

  @moduletag capture_log: true

  defmodule RecordingBackend do
    @behaviour Gobusgo.Writer

    @impl Gobusgo.Writer
    def write(request, options) do
      send(Keyword.fetch!(options, :recipient), {:written, request})
      :ok
    end
  end

  defmodule AcknowledgingPublisher do
    @behaviour Gobusgo.Publisher

    @impl Gobusgo.Publisher
    def publish(_records, _options), do: :ok
  end

  @fixture_directory Path.expand("../../fixtures/one_bus_away", __DIR__)
  @stub_name Sources
  @gate Module.concat(__MODULE__, Gate)
  @tasks Module.concat(__MODULE__, Tasks)
  @demand Module.concat(__MODULE__, Demand)
  @clock_key {__MODULE__, :clock}
  @settings %Gobusgo.Config.OneBusAway{
    base_url: "https://oba.example.test",
    api_key: "test-key-3f9a1c07be52"
  }

  # The requests go through a gate of their own that refills at once, so
  # the tests neither wait on the application's gate nor spend its budget.
  setup do
    start_supervised!({Gobusgo.OneBusAway.RequestGate, name: @gate, refill_interval_ms: 1})
    start_supervised!({Task.Supervisor, name: @tasks})
    clock = :atomics.new(1, signed: true)

    start_supervised!(
      {Demand,
       name: @demand,
       datasets: DemandKey.datasets(),
       monotonic_time_ms: fn -> :atomics.get(clock, 1) end}
    )

    Process.put(@clock_key, clock)
    :ok
  end

  defp advance_clock(duration_ms), do: :atomics.add(Process.get(@clock_key), 1, duration_ms)

  # The interval the vehicle source's policy decides from what its signals
  # function reads now.
  defp vehicle_interval_ms do
    %{cadence: cadence} = vehicles([])
    Cadence.interval_ms(cadence.policy, cadence.signals.())
  end

  # A process that views vehicles until the test ends it.
  defp start_viewer do
    test = self()

    viewer =
      spawn(fn ->
        send(test, {:viewing, self(), Demand.register(@demand, DemandKey.vehicles())})
        Process.sleep(:infinity)
      end)

    assert_receive {:viewing, ^viewer, :ok}
    viewer
  end

  # Ends the viewer and reads the registry until it holds one viewer fewer:
  # the registry learns of the exit in its own time, and reads its clock
  # then.
  defp end_viewer(viewer) do
    viewer_count = Demand.holder_count(@demand, DemandKey.vehicles())
    reference = Process.monitor(viewer)
    Process.exit(viewer, :kill)
    assert_receive {:DOWN, ^reference, :process, ^viewer, :killed}
    await_viewer_count(viewer_count - 1, 500)
  end

  defp await_viewer_count(expected, reads_left) do
    case Demand.holder_count(@demand, DemandKey.vehicles()) do
      ^expected ->
        :ok

      count when reads_left > 1 ->
        assert count > expected
        Process.sleep(1)
        await_viewer_count(expected, reads_left - 1)

      count ->
        flunk("expected #{expected} viewers, got: #{count}")
    end
  end

  defp specs(options) do
    Sources.specs(
      @settings,
      Keyword.merge(
        [
          demand: @demand,
          vehicle_cycle_options: [task_supervisor: @tasks],
          route_cycle_options: [task_supervisor: @tasks],
          arrival_cycle_options: [task_supervisor: @tasks]
        ],
        options
      )
    )
  end

  defp agency_discovery(record_options) do
    assert [spec, _vehicles, _routes, _arrivals] = specs(agency_record_options: record_options)
    spec
  end

  defp vehicles(cycle_options) do
    assert [_agencies, spec, _routes, _arrivals] =
             specs(vehicle_cycle_options: [task_supervisor: @tasks] ++ cycle_options)

    spec
  end

  defp routes(cycle_options) do
    assert [_agencies, _vehicles, spec, _arrivals] =
             specs(route_cycle_options: [task_supervisor: @tasks] ++ cycle_options)

    spec
  end

  defp arrivals(cycle_options) do
    assert [_agencies, _vehicles, _routes, spec] =
             specs(arrival_cycle_options: [task_supervisor: @tasks] ++ cycle_options)

    spec
  end

  describe "assert_tombstone_grace/1" do
    # Each row is the longest interval between two vehicle fetches against
    # a grace period of 300,000 ms, which has to span four of them.
    for {label, interval_ms_max, accepted?} <- [
          {"a quarter of the grace period", 75_000, true},
          {"one millisecond over a quarter of the grace period", 75_001, false},
          {"the grace period itself", 300_000, false}
        ] do
      test "#{if accepted?, do: "accepts", else: "refuses"} a longest interval of #{label}" do
        relation = %{interval_ms_max: unquote(interval_ms_max), tombstone_grace_ms: 300_000}

        if unquote(accepted?) do
          assert Sources.assert_tombstone_grace(relation) == :ok
        else
          assert_raise AssertionError, ~r/grace/, fn ->
            Sources.assert_tombstone_grace(relation)
          end
        end
      end
    end

    test "accepts the vehicle source's longest interval under the vehicle view's grace period" do
      %{cadence: %{policy: {:steps, %{interval_ms_max: interval_ms_max}}}} = vehicles([])

      assert Sources.assert_tombstone_grace(%{
               interval_ms_max: interval_ms_max,
               tombstone_grace_ms: VehicleView.State.tombstone_grace_ms()
             }) == :ok
    end
  end

  describe "specs/2" do
    test "names a cadence for every source, and an interval for none" do
      for spec <- specs([]) do
        assert %{cadence: %{policy: {kind, _detail}, signals: signals}} = spec
        assert kind in [:fixed, :steps]
        assert is_function(signals, 0)
        refute is_map_key(spec, :interval_ms)
      end
    end

    # Each row is a source and the interval it runs at, which its policy
    # has to decide from the signals its own function returns. Nobody views
    # vehicles here.
    for {name, interval_ms} <- [
          {Gobusgo.OneBusAway.AgencyScheduler, 60_000},
          {Gobusgo.OneBusAway.VehicleScheduler, 60_000},
          {Gobusgo.OneBusAway.RouteScheduler, 60_000},
          {Gobusgo.OneBusAway.ArrivalScheduler, 5_000}
        ] do
      test "has #{inspect(name)} run every #{interval_ms} ms" do
        spec = Enum.find(specs([]), &(&1.name == unquote(name)))

        assert Cadence.interval_ms(spec.cadence.policy, spec.cadence.signals.()) ==
                 unquote(interval_ms)
      end
    end

    test "returns specs a scheduler accepts" do
      for spec <- specs([]) do
        assert Scheduler.assert_spec(spec) == :ok
      end
    end

    test "holds agency discovery, once a minute" do
      assert %{name: Gobusgo.OneBusAway.AgencyScheduler, cadence: %{policy: {:fixed, 60_000}}} =
               agency_discovery([])
    end

    test "gives agency discovery a deadline inside its interval" do
      spec = agency_discovery([])

      assert spec.deadline_ms >= 1
      assert spec.deadline_ms < Cadence.interval_ms_min(spec.cadence.policy)
    end

    test "runs agency discovery by recording one response" do
      Req.Test.stub(@stub_name, fn conn ->
        body = File.read!(Path.join(@fixture_directory, "agencies_with_coverage.json"))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end)

      spec =
        agency_discovery(
          fetch_options: [
            plug: {Req.Test, @stub_name},
            gate: @gate,
            max_retries: 0,
            retry_delay_ms_base: 1
          ],
          write_options: [backend: RecordingBackend, recipient: self()],
          publish_options: [backend: AcknowledgingPublisher]
        )

      assert {:ok, %{destination: destination}} = spec.run.()
      assert_received {:written, %{destination: ^destination}}
    end

    test "holds the vehicle source, between every ten seconds and every minute" do
      assert %{
               name: Gobusgo.OneBusAway.VehicleScheduler,
               cadence: %{policy: {:steps, %{interval_ms_min: 10_000, interval_ms_max: 60_000}}}
             } = vehicles([])
    end

    test "names the vehicle policy's shortest interval as the vehicle source's" do
      %{cadence: %{policy: {:steps, %{interval_ms_min: interval_ms_min}}}} = vehicles([])

      assert Sources.vehicle_interval_ms_min() == interval_ms_min
    end

    test "runs the vehicle source every minute while nobody has viewed vehicles" do
      assert vehicle_interval_ms() == 60_000
    end

    for viewer_count <- [1, 2, 25] do
      test "runs the vehicle source every ten seconds with #{viewer_count} viewers" do
        for _viewer <- 1..unquote(viewer_count), do: start_viewer()

        assert vehicle_interval_ms() == 10_000
      end
    end

    # Each row is the time since the last viewer left, around the hold of
    # 60,000 ms: just inside it, exactly at it, and just past it.
    for {label, absence_ms, interval_ms} <- [
          {"one millisecond inside the hold", 59_999, 10_000},
          {"exactly at the hold", 60_000, 60_000},
          {"one millisecond past the hold", 60_001, 60_000}
        ] do
      test "runs the vehicle source every #{interval_ms} ms #{label} after the last viewer left" do
        viewer = start_viewer()
        end_viewer(viewer)

        advance_clock(unquote(absence_ms))

        assert vehicle_interval_ms() == unquote(interval_ms)
      end
    end

    test "runs the vehicle source every ten seconds again when a viewer comes back" do
      viewer = start_viewer()
      end_viewer(viewer)
      advance_clock(60_000)
      assert vehicle_interval_ms() == 60_000

      start_viewer()

      assert vehicle_interval_ms() == 10_000
    end

    test "has the vehicle source's signals read fail while the registry is down" do
      %{cadence: cadence} = vehicles([])
      stop_supervised!(Demand)

      assert catch_exit(cadence.signals.())
    end

    test "gives the vehicle source a deadline inside its interval" do
      spec = vehicles([])

      assert spec.deadline_ms >= 1
      assert spec.deadline_ms < Cadence.interval_ms_min(spec.cadence.policy)
    end

    test "runs the vehicle source by recording every agency's vehicles" do
      Req.Test.stub(@stub_name, fn conn ->
        body = File.read!(Path.join(@fixture_directory, "vehicles_for_agency.json"))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end)

      spec =
        vehicles(
          agency_ids: fn -> ["1", "40"] end,
          record_options: [
            fetch_options: [plug: {Req.Test, @stub_name}, gate: @gate],
            write_options: [backend: RecordingBackend, recipient: self()],
            publish_options: [backend: AcknowledgingPublisher]
          ]
        )

      assert {:ok, %{agency_count: 2, recorded_count: 2}} = spec.run.()
      assert_received {:written, %{destination: _first}}
      assert_received {:written, %{destination: _second}}
    end

    test "holds the route source, every minute" do
      assert %{name: Gobusgo.OneBusAway.RouteScheduler, cadence: %{policy: {:fixed, 60_000}}} =
               routes([])
    end

    test "gives the route source a deadline inside its interval" do
      spec = routes([])

      assert spec.deadline_ms >= 1
      assert spec.deadline_ms < Cadence.interval_ms_min(spec.cadence.policy)
    end

    test "runs the route source by recording the routes of an agency that has none", context do
      route_view = Module.concat(__MODULE__, "RouteView#{context.line}")

      start_supervised!(
        {FetchView,
         name: route_view,
         pubsub: Gobusgo.PubSub,
         records: Gobusgo.OneBusAway.RouteBatch.Records,
         id_count_max: 1}
      )

      Req.Test.stub(@stub_name, fn conn ->
        body = File.read!(Path.join(@fixture_directory, "routes_for_agency.json"))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end)

      spec =
        routes(
          agency_ids: fn -> ["40"] end,
          route_view: route_view,
          route_path_view: Module.concat(__MODULE__, NoRoutePathView),
          record_options: [
            fetch_options: [plug: {Req.Test, @stub_name}, gate: @gate],
            write_options: [backend: RecordingBackend, recipient: self()],
            publish_options: [backend: AcknowledgingPublisher]
          ]
        )

      assert {:ok, %{due_count: 1, recorded_count: 1}} = spec.run.()
      assert_received {:written, %{destination: "raw/oba/routes-for-agency/" <> _name}}
    end

    test "holds the arrival source, every five seconds" do
      assert %{name: Gobusgo.OneBusAway.ArrivalScheduler, cadence: %{policy: {:fixed, 5_000}}} =
               arrivals([])
    end

    test "gives the arrival source a deadline inside its interval" do
      spec = arrivals([])

      assert spec.deadline_ms >= 1
      assert spec.deadline_ms < Cadence.interval_ms_min(spec.cadence.policy)
    end

    test "runs the arrival source by recording one of the open stops that are due", context do
      arrival_view = Module.concat(__MODULE__, "ArrivalView#{context.line}")

      start_supervised!(
        {FetchView,
         name: arrival_view,
         pubsub: Gobusgo.PubSub,
         records: ArrivalBatch.Records,
         id_count_max: 2}
      )

      Req.Test.stub(@stub_name, fn conn ->
        body = File.read!(Path.join(@fixture_directory, "arrivals_and_departures_for_stop.json"))

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end)

      spec =
        arrivals(
          stop_ids: fn -> ["95_7", "95_8"] end,
          arrival_view: arrival_view,
          record_options: [
            fetch_options: [plug: {Req.Test, @stub_name}, gate: @gate],
            write_options: [backend: RecordingBackend, recipient: self()],
            publish_options: [backend: AcknowledgingPublisher]
          ]
        )

      assert {:ok, %{open_count: 2, due_count: 2, recorded_count: 1, deferred_count: 1}} =
               spec.run.()

      assert_received {:written,
                       %{destination: "raw/oba/arrivals-and-departures-for-stop/" <> _name}}

      refute_received {:written, _request}
    end

    # Each row is a count of open stops and whether the arrival source
    # fetches again the one of them whose fetch is a minute old. The view is
    # started and filled here, every other stop with a fetch a second old,
    # and the cycle reads the time the test names.
    for {open_count, written_count} <- [{12, 1}, {13, 0}] do
      test "runs the arrival source at a refresh age scaled to #{open_count} open stops",
           context do
        now = ~U[2026-10-07 02:30:00Z]
        view = Module.concat(__MODULE__, "ArrivalView#{context.line}")

        start_supervised!(
          {FetchView,
           name: view, pubsub: Gobusgo.PubSub, records: ArrivalBatch.Records, id_count_max: 100}
        )

        stop_ids = ["95_7" | for(index <- 2..unquote(open_count), do: "95_#{index + 100}")]

        for {stop_id, age_seconds} <- Enum.zip(stop_ids, [60 | List.duplicate(1, 99)]) do
          record =
            ArrivalBatch.Records.build(%{
              stop_id: stop_id,
              destination: "raw/oba/arrivals-and-departures-for-stop/seeded.json.gz",
              fetched_at: DateTime.add(now, -age_seconds, :second),
              data_sha256: String.duplicate("ab", 32),
              request_id: "0199c4a2-7e1b-7a3f-9d20-000000000001",
              arrivals: []
            })

          :ok = FetchView.apply_records(view, [record.value])
        end

        Req.Test.stub(@stub_name, fn conn ->
          body =
            File.read!(Path.join(@fixture_directory, "arrivals_and_departures_for_stop.json"))

          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(200, body)
        end)

        spec =
          arrivals(
            stop_ids: fn -> stop_ids end,
            arrival_view: view,
            clock: fn -> now end,
            record_options: [
              fetch_options: [plug: {Req.Test, @stub_name}, gate: @gate],
              write_options: [backend: RecordingBackend, recipient: self()],
              publish_options: [backend: AcknowledgingPublisher]
            ]
          )

        assert {:ok, %{open_count: unquote(open_count), recorded_count: unquote(written_count)}} =
                 spec.run.()
      end
    end
  end

  describe "arrival_refresh_policy/0" do
    # Each row is a count of open stops and the age at which the arrival
    # source fetches a stop again: no stop, the counts on each side of where
    # the age leaves 30 seconds and of where it reaches five minutes, one
    # between them, and one far past the stops a registry holds.
    for {open_count, refresh_age_ms} <- [
          {0, 30_000},
          {1, 30_000},
          {6, 30_000},
          {7, 35_000},
          {12, 60_000},
          {59, 295_000},
          {60, 300_000},
          {61, 300_000},
          {2_000, 300_000},
          {10 ** 30, 300_000}
        ] do
      test "decides a refresh age of #{refresh_age_ms} ms for #{open_count} open stops" do
        signals = %{item_count: unquote(open_count)}

        assert Cadence.interval_ms(Sources.arrival_refresh_policy(), signals) ==
                 unquote(refresh_age_ms)
      end
    end

    test "spaces the stops by the interval between the arrival source's requests" do
      spec = arrivals([])
      request_interval_ms = Cadence.interval_ms(spec.cadence.policy, spec.cadence.signals.())

      assert {:proportional, %{item_spacing_ms: ^request_interval_ms}} =
               Sources.arrival_refresh_policy()
    end

    test "is a policy the cadence service accepts" do
      assert Cadence.assert_policy(Sources.arrival_refresh_policy()) == :ok
    end
  end
end
