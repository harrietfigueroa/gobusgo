defmodule Gobusgo.Gbfs.VehicleStatusCycleTest do
  # Checks the shared vehicle source's demand rules against a demand
  # registry started for the test, whose holders the test registers and
  # releases from processes of its own, by asking Gobusgo.Cadence what the
  # source's policy decides from its signals; then runs the cycle against a
  # Req.Test stub that answers 404 for every address, and reads its log.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.Cadence
  alias Gobusgo.Demand
  alias Gobusgo.Gbfs.DemandKey
  alias Gobusgo.Gbfs.VehicleStatusBatch.Records
  alias Gobusgo.Gbfs.VehicleStatusCycle
  alias Gobusgo.Gbfs.VehicleStatusView
  alias Gobusgo.Publisher.InProcess
  alias Gobusgo.Scheduler

  @interval_ms 60_000
  @stub_name VehicleStatusCycle

  setup context do
    demand = Module.concat(__MODULE__, "Demand#{context.line}")

    start_supervised!(
      {Demand, name: demand, datasets: DemandKey.datasets(), holder_item_count_max: 4}
    )

    %{demand: demand}
  end

  defp spec(context) do
    VehicleStatusCycle.spec(%{interval_ms: @interval_ms},
      demand: context.demand,
      cycle_options: []
    )
  end

  defp decision(spec), do: Cadence.decision(spec.cadence.policy, spec.cadence.signals.())

  # A viewer is a process that holds the key until the test stops it.
  defp start_viewer(demand) do
    test = self()

    viewer =
      spawn(fn ->
        :ok = Demand.register(demand, DemandKey.shared_vehicles())
        send(test, :registered)
        Process.sleep(:infinity)
      end)

    assert_receive :registered
    viewer
  end

  defp stop_viewer(demand, viewer) do
    Process.exit(viewer, :kill)
    wait_for_count(demand, 0)
  end

  defp wait_for_count(demand, count) do
    Enum.reduce_while(1..100//1, nil, fn _attempt, nil ->
      case Demand.holder_count(demand, DemandKey.shared_vehicles()) do
        ^count -> {:halt, :ok}
        _other -> {:cont, nil}
      end
    end)
  end

  describe "the source's cadence" do
    test "pauses while no page shows the shared vehicles", context do
      assert decision(spec(context)) == :paused
    end

    test "fetches once per interval for one viewer", context do
      start_viewer(context.demand)

      assert decision(spec(context)) == {:interval, @interval_ms}
    end

    test "fetches once per interval for every viewer together", context do
      for _viewer <- 1..3, do: start_viewer(context.demand)

      assert decision(spec(context)) == {:interval, @interval_ms}
    end

    test "pauses again once the last viewer leaves", context do
      viewer = start_viewer(context.demand)
      stop_viewer(context.demand, viewer)

      assert decision(spec(context)) == :paused
    end

    test "runs at the configured interval", context do
      spec =
        VehicleStatusCycle.spec(%{interval_ms: 300_000},
          demand: context.demand,
          cycle_options: []
        )

      start_viewer(context.demand)

      assert decision(spec) == {:interval, 300_000}
    end

    test "has a deadline under its shortest interval", context do
      assert Scheduler.assert_spec(spec(context)) == :ok
    end
  end

  describe "a run that finds the feed not published" do
    setup context do
      Req.Test.stub(@stub_name, &Plug.Conn.send_resp(&1, 404, "not found"))
      view = Module.concat(__MODULE__, "View#{context.line}")

      start_supervised!(
        {VehicleStatusView, name: view, pubsub: Gobusgo.PubSub, system_count_max: 4}
      )

      subscribers = %{Records.topic() => {VehicleStatusView, :apply_records, [view]}}

      options = [
        view: view,
        record_options: [
          fetch_options: [plug: {Req.Test, @stub_name}],
          publish_options: [backend: InProcess, subscribers: subscribers]
        ]
      ]

      %{options: options}
    end

    test "is a run that succeeds", context do
      assert {:ok, %{not_published_count: 1, failed_count: 0}} =
               VehicleStatusCycle.run(context.options)
    end

    test "logs a warning once however many runs find it", context do
      log =
        capture_log(fn ->
          for _run <- 1..3, do: VehicleStatusCycle.run(context.options)
        end)

      assert length(String.split(log, "[warning] Shared vehicle feed not published")) == 2
    end
  end
end
