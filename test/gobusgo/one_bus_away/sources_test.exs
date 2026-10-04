defmodule Gobusgo.OneBusAway.SourcesTest do
  # Reads the source specs as values, and calls each source's run with a
  # Req.Test stub serving a JSON fixture and writer and publisher doubles
  # defined here, so the run is observed through the writer contract with no
  # network access, no storage, and no subscriber.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.Sources

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
  @settings %{base_url: "https://oba.example.test", api_key: "test-key-3f9a1c07be52"}

  # The requests go through a gate of their own that refills at once, so
  # the tests neither wait on the application's gate nor spend its budget.
  setup do
    start_supervised!({Gobusgo.OneBusAway.RequestGate, name: @gate, refill_interval_ms: 1})
    start_supervised!({Task.Supervisor, name: @tasks})
    :ok
  end

  defp specs(options) do
    Sources.specs(
      @settings,
      Keyword.merge([vehicle_cycle_options: [task_supervisor: @tasks]], options)
    )
  end

  defp agency_discovery(record_options) do
    assert [spec, _vehicles] = specs(agency_record_options: record_options)
    spec
  end

  defp vehicles(cycle_options) do
    assert [_agencies, spec] =
             specs(vehicle_cycle_options: [task_supervisor: @tasks] ++ cycle_options)

    spec
  end

  describe "specs/2" do
    test "holds agency discovery, once a minute" do
      assert %{name: Gobusgo.OneBusAway.AgencyScheduler, interval_ms: 60_000} =
               agency_discovery([])
    end

    test "gives agency discovery a deadline inside its interval" do
      spec = agency_discovery([])

      assert spec.deadline_ms >= 1
      assert spec.deadline_ms < spec.interval_ms
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

    test "holds the vehicle source, every five seconds" do
      assert %{name: Gobusgo.OneBusAway.VehicleScheduler, interval_ms: 5_000} = vehicles([])
    end

    test "gives the vehicle source a deadline inside its interval" do
      spec = vehicles([])

      assert spec.deadline_ms >= 1
      assert spec.deadline_ms < spec.interval_ms
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
  end
end
