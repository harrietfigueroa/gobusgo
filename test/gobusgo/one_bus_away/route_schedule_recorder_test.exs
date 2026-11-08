defmodule Gobusgo.OneBusAway.RouteScheduleRecorderTest do
  # Drives record/2 with Req.Test stubs serving JSON fixtures and with writer
  # and publisher doubles defined here, so every outcome is observed through
  # the writer and publisher contracts with no network access, no storage,
  # and no subscriber.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.RawRouteScheduleResponse
  alias Gobusgo.OneBusAway.RawRouteScheduleResponse.StoredEvent
  alias Gobusgo.OneBusAway.RouteScheduleRecorder

  defmodule RecordingBackend do
    @behaviour Gobusgo.Writer

    @impl Gobusgo.Writer
    def write(request, options) do
      send(Keyword.fetch!(options, :recipient), {:written, request})
      Keyword.get(options, :result, :ok)
    end
  end

  defmodule RecordingPublisher do
    @behaviour Gobusgo.Publisher

    @impl Gobusgo.Publisher
    def publish(records, options) do
      send(Keyword.fetch!(options, :recipient), {:published, records})
      Keyword.fetch!(options, :result)
    end
  end

  @fixture_directory Path.expand("../../fixtures/one_bus_away", __DIR__)
  @stub_name RouteScheduleRecorder
  @gate Module.concat(__MODULE__, Gate)
  @api_key "test-key-3f9a1c07be52"
  @settings %Gobusgo.Config.OneBusAway{base_url: "https://oba.example.test", api_key: @api_key}
  @request_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"
  @event_id "0199c4a2-7e1b-7a3f-9d20-0000000000ff"
  @fetched_at ~U[2026-11-06 23:15:00.500000Z]

  # The requests go through a gate of their own that refills at once, so
  # the tests neither wait on the application's gate nor spend its budget.
  setup do
    start_supervised!({Gobusgo.OneBusAway.RequestGate, name: @gate, refill_interval_ms: 1})
    :ok
  end

  defp fixture(name), do: File.read!(Path.join(@fixture_directory, name <> ".json"))

  defp stub_fixture(name, status \\ 200) do
    Req.Test.stub(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, fixture(name))
    end)
  end

  defp record(options \\ []) do
    defaults = [
      route_id: "19_41",
      service_date: ~D[2026-11-07],
      request_id: @request_id,
      event_id: fn -> @event_id end,
      fetch_options: [
        plug: {Req.Test, @stub_name},
        gate: @gate,
        max_retries: 0,
        retry_delay_ms_base: 1,
        clock: fn -> @fetched_at end
      ],
      write_options: [backend: RecordingBackend, recipient: self()],
      publish_options: [backend: RecordingPublisher, recipient: self(), result: :ok]
    ]

    RouteScheduleRecorder.record(@settings, Keyword.merge(defaults, options))
  end

  describe "record/2 success" do
    setup do
      stub_fixture("schedule_for_route")
      :ok
    end

    test "stores the schedule under the route's and the service date's destination" do
      assert {:ok, %{destination: destination, route_id: "19_41"}} = record()

      assert destination =~
               "raw/oba/schedule-for-route/dt=2026-11-06/route=19_41/service-date=2026-11-07/" <>
                 "20261106T231500Z_#{@request_id}_"

      assert_received {:written, %{destination: ^destination, content: content}}

      assert {:ok,
              %{route_id: "19_41", service_date: ~D[2026-11-07], schedule: %{trips: [_ | _]}}} =
               RawRouteScheduleResponse.parse(%{
                 destination: destination,
                 content: :zlib.gunzip(content)
               })
    end

    test "publishes one response stored event that names the stored response" do
      assert {:ok, %{event_published: true} = recorded} = record()

      assert_received {:published, [event]}

      assert {:ok, %{route_id: "19_41", service_date: ~D[2026-11-07], destination: destination}} =
               StoredEvent.decode(event.value)

      assert destination == recorded.destination
    end

    test "keeps the response recorded when its event is not published" do
      options = [backend: RecordingPublisher, recipient: self(), result: {:error, :unknown_topic}]

      assert {:ok, %{event_published: false}} = record(publish_options: options)
      assert_received {:written, _request}
    end

    test "logs nothing" do
      # The capture also holds lines other tests log meanwhile, so the
      # assertion is on the lines of this process.
      log = capture_log([metadata: :all], fn -> record() end)

      refute log =~ "pid=#{:erlang.pid_to_list(self())} "
    end

    test "never stores the key" do
      assert {:ok, _recorded} = record()

      assert_received {:written, %{destination: destination, content: content}}
      refute destination =~ @api_key
      refute :zlib.gunzip(content) =~ @api_key
    end
  end

  describe "record/2 without service" do
    test "returns the route and the date, and stores and publishes nothing" do
      stub_fixture("schedule_for_route_no_service")

      assert record() == {:no_service, %{route_id: "19_41", service_date: ~D[2026-11-07]}}
      refute_received {:written, _request}
      refute_received {:published, _records}
    end
  end

  describe "record/2 failure" do
    test "returns a failed fetch and stores and publishes nothing" do
      stub_fixture("unauthorized", 401)

      assert record() == {:error, {:fetch, {:http_status, 401}}}
      refute_received {:written, _request}
      refute_received {:published, _records}
    end

    test "returns a failed write and publishes nothing" do
      stub_fixture("schedule_for_route")
      options = [backend: RecordingBackend, recipient: self(), result: {:error, :io_failure}]

      assert record(write_options: options) == {:error, {:write, :io_failure}}
      refute_received {:published, _records}
    end

    test "raises for a response that breaks the documented schema and stores nothing" do
      Req.Test.stub(@stub_name, fn conn ->
        body =
          "schedule_for_route"
          |> fixture()
          |> JSON.decode!()
          |> put_in(["data", "entry", "routeId"], "19_42")
          |> JSON.encode!()

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, body)
      end)

      assert_raise AssertionError, fn -> record() end
      refute_received {:written, _request}
    end
  end
end
