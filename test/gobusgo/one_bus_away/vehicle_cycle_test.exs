defmodule Gobusgo.OneBusAway.VehicleCycleTest do
  # Drives run/2 with a Req.Test stub that answers each agency's path its own
  # way and with writer and publisher doubles defined here, so the outcome of
  # every agency is observed through the writer contract and the returned
  # counts with no network access and no storage.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.OneBusAway.VehicleCycle

  @moduletag capture_log: true

  defmodule RecordingBackend do
    @behaviour Gobusgo.Writer

    @impl Gobusgo.Writer
    def write(%{destination: destination}, options) do
      send(Keyword.fetch!(options, :recipient), {:written, destination})
      :ok
    end
  end

  defmodule StubPublisher do
    @behaviour Gobusgo.Publisher

    @impl Gobusgo.Publisher
    def publish(_records, options), do: Keyword.fetch!(options, :result)
  end

  @fixture_directory Path.expand("../../fixtures/one_bus_away", __DIR__)
  @stub_name VehicleCycle
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

  defp fixture(name), do: File.read!(Path.join(@fixture_directory, name <> ".json"))

  # Answers by the agency in the request path: `answers` maps an agency
  # identifier to `{status, fixture}` or to `:stall`.
  defp stub_agencies(answers) do
    Req.Test.stub(@stub_name, fn conn ->
      "/api/where/vehicles-for-agency/" <> file = conn.request_path

      case Map.fetch!(answers, String.replace_suffix(file, ".json", "")) do
        :stall ->
          Process.sleep(:infinity)

        {status, name} ->
          conn
          |> Plug.Conn.put_resp_content_type("application/json")
          |> Plug.Conn.send_resp(status, fixture(name))
      end
    end)
  end

  defp run(agency_ids, options \\ []) do
    defaults = [
      task_supervisor: @tasks,
      agency_ids: fn -> agency_ids end,
      record_options: [
        fetch_options: [plug: {Req.Test, @stub_name}, gate: @gate, retry_delay_ms_base: 1],
        write_options: [backend: RecordingBackend, recipient: self()],
        publish_options: [backend: StubPublisher, result: :ok]
      ]
    ]

    VehicleCycle.run(@settings, Keyword.merge(defaults, options))
  end

  defp written_agencies(agencies \\ []) do
    receive do
      {:written, destination} ->
        [_match, agency] = Regex.run(~r{/agency=([^/]+)/}, destination)
        written_agencies(agencies ++ [agency])
    after
      0 -> agencies
    end
  end

  @ok {200, "vehicles_for_agency"}

  describe "run/2" do
    test "records every agency, one after another in identifier order" do
      stub_agencies(%{"1" => @ok, "40" => @ok, "95" => {200, "vehicles_for_agency_empty"}})

      assert run(["40", "95", "1"]) ==
               {:ok,
                %{
                  agency_count: 3,
                  recorded_count: 3,
                  failed_count: 0,
                  skipped_count: 0,
                  unannounced_count: 0
                }}

      assert written_agencies() == ["1", "40", "95"]
    end

    test "returns no failure when there is no agency to fetch" do
      assert {:ok, %{agency_count: 0, recorded_count: 0}} = run([])
    end

    for {label, answer} <- [
          {"answers with a server error", {500, "server_error"}},
          {"answers with a refused key", {401, "unauthorized"}},
          {"raises on a broken schema", {200, "vehicles_for_agency_schema_violation"}}
        ] do
      test "goes on to the next agency when one #{label}" do
        stub_agencies(%{"1" => @ok, "40" => unquote(Macro.escape(answer)), "95" => @ok})

        assert {:ok, %{agency_count: 3, recorded_count: 2, failed_count: 1}} =
                 run(["1", "40", "95"])

        assert written_agencies() == ["1", "95"]
      end
    end

    test "goes on to the next agency when one stalls past the agency deadline" do
      stub_agencies(%{"1" => :stall, "40" => @ok})

      assert {:ok, %{agency_count: 2, recorded_count: 1, failed_count: 1}} =
               run(["1", "40"], agency_deadline_ms: 1_000)

      assert written_agencies() == ["40"]
    end

    test "does not retry a failed fetch within the cycle" do
      test_process = self()

      Req.Test.stub(@stub_name, fn conn ->
        send(test_process, :requested)
        Plug.Conn.send_resp(conn, 500, fixture("server_error"))
      end)

      assert run(["40"]) == {:error, :nothing_recorded}
      assert_received :requested
      refute_received :requested
    end

    test "skips the agencies its budget does not reach" do
      stub_agencies(%{"1" => :stall, "40" => @ok})

      assert {:error, :nothing_recorded} = run(["1", "40"], budget_ms: 100)
      assert written_agencies() == []
    end

    test "counts a response stored without its event" do
      stub_agencies(%{"40" => @ok})

      record_options = [
        fetch_options: [plug: {Req.Test, @stub_name}, gate: @gate],
        write_options: [backend: RecordingBackend, recipient: self()],
        publish_options: [backend: StubPublisher, result: {:error, :unavailable}]
      ]

      assert {:ok, %{recorded_count: 1, unannounced_count: 1}} =
               run(["40"], record_options: record_options)
    end
  end

  describe "run/2 logging" do
    # The capture also holds lines other tests log meanwhile, so these read
    # the lines of the test's own process, where run/2 logs.
    defp own_log(function) do
      [metadata: :all]
      |> capture_log(function)
      |> String.split("\n", trim: true)
      |> Enum.filter(&String.contains?(&1, "pid=#{:erlang.pid_to_list(self())} "))
    end

    test "logs one info line for a cycle that records every agency" do
      stub_agencies(%{"1" => @ok, "40" => @ok})

      assert [line] = own_log(fn -> run(["1", "40"]) end)
      assert line =~ "[info] OneBusAway vehicle cycle finished"
      assert line =~ "recorded_count=2"
    end

    test "logs a warning for a cycle that records some agencies" do
      stub_agencies(%{"1" => @ok, "40" => {500, "server_error"}})

      assert [line] = own_log(fn -> run(["1", "40"]) end)
      assert line =~ "[warning] OneBusAway vehicle cycle finished degraded"
      assert line =~ "failed_count=1"
    end

    test "logs an error for a cycle that records none" do
      stub_agencies(%{"40" => {500, "server_error"}})

      assert [line] = own_log(fn -> run(["40"]) end)
      assert line =~ "[error] OneBusAway vehicle cycle failed"
    end
  end
end
