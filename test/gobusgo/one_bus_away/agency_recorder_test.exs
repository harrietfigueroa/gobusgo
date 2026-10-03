defmodule Gobusgo.OneBusAway.AgencyRecorderTest do
  # Drives record/2 with Req.Test stubs serving JSON fixtures and with writer
  # and publisher doubles defined here, so every outcome is observed through
  # the writer and publisher contracts with no network access, no storage,
  # and no subscriber.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.AgencyRecorder
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.OneBusAway.RawAgencyResponse.StoredEvent
  alias Gobusgo.RequestId

  @moduletag capture_log: true

  defmodule RecordingBackend do
    @behaviour Gobusgo.Writer

    @impl Gobusgo.Writer
    def write(request, options) do
      send(Keyword.fetch!(options, :recipient), {:written, request})
      :ok
    end
  end

  defmodule RefusingBackend do
    @behaviour Gobusgo.Writer

    @impl Gobusgo.Writer
    def write(request, options) do
      send(Keyword.fetch!(options, :recipient), {:refused, request})
      {:error, Keyword.fetch!(options, :reason)}
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
  @stub_name AgencyRecorder
  @gate Module.concat(__MODULE__, Gate)
  @api_key "test-key-3f9a1c07be52"
  @settings %{base_url: "https://oba.example.test", api_key: @api_key}
  @request_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"
  @event_id "0199c4a2-7e1b-7a3f-9d20-0000000000ff"
  @fetched_at ~U[2026-10-02 03:15:00.500000Z]

  # The requests go through a gate of their own that refills at once, so
  # the tests neither wait on the application's gate nor spend its budget.
  setup do
    start_supervised!({Gobusgo.OneBusAway.RequestGate, name: @gate, refill_interval_ms: 1})
    :ok
  end

  defp fixture(name), do: File.read!(Path.join(@fixture_directory, name <> ".json"))

  defp stub_body(body, status \\ 200) do
    Req.Test.stub(@stub_name, fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(status, body)
    end)
  end

  defp stub_fixture(name, status \\ 200), do: stub_body(fixture(name), status)

  defp fetch_options do
    [
      plug: {Req.Test, @stub_name},
      gate: @gate,
      max_retries: 0,
      retry_delay_ms_base: 1,
      clock: fn -> @fetched_at end
    ]
  end

  defp record(options \\ []) do
    defaults = [
      request_id: @request_id,
      event_id: fn -> @event_id end,
      fetch_options: fetch_options(),
      write_options: [backend: RecordingBackend, recipient: self()],
      publish_options: publish_options(:ok)
    ]

    AgencyRecorder.record(@settings, Keyword.merge(defaults, options))
  end

  defp publish_options(result) do
    [backend: RecordingPublisher, recipient: self(), result: result]
  end

  defp written_content do
    assert_received {:written, %{content: stored}}
    stored |> :zlib.gunzip() |> JSON.decode!()
  end

  describe "record/2 success" do
    setup do
      stub_fixture("agencies_with_coverage")
      data = "agencies_with_coverage" |> fixture() |> JSON.decode!() |> Map.fetch!("data")
      %{data_sha256: RawAgencyResponse.data_sha256(data)}
    end

    test "writes to the destination named by fetch time, request, and data hash", %{
      data_sha256: data_sha256
    } do
      assert {:ok, _recorded} = record()

      destination =
        "raw/oba/agencies-with-coverage/dt=2026-10-02/" <>
          "20261002T031500Z_#{@request_id}_#{binary_part(data_sha256, 0, 12)}.json.gz"

      assert_received {:written, %{destination: ^destination}}
    end

    test "stores the envelope with its agencies, coverage, and references" do
      assert {:ok, _recorded} = record()

      assert written_content()["body"] == JSON.decode!(fixture("agencies_with_coverage"))
    end

    test "stores the retrieval metadata", %{data_sha256: data_sha256} do
      assert {:ok, _recorded} = record()

      assert written_content()["meta"] == %{
               "dataSha256" => data_sha256,
               "envelopeCurrentTime" => 1_710_953_797_130,
               "envelopeVersion" => 2,
               "fetchedAt" => "2026-10-02T03:15:00Z",
               "host" => "oba.example.test",
               "httpStatus" => 200,
               "method" => "GET",
               "requestId" => @request_id
             }
    end

    test "returns what it stored and where", %{data_sha256: data_sha256} do
      assert {:ok, recorded} = record()
      assert_received {:written, %{destination: destination}}

      assert recorded == %{
               destination: destination,
               request_id: @request_id,
               fetched_at: ~U[2026-10-02 03:15:00Z],
               data_sha256: data_sha256
             }
    end

    test "writes exactly once" do
      assert {:ok, _recorded} = record()

      assert_received {:written, _request}
      refute_received {:written, _request}
    end

    test "generates a request identifier when none is given" do
      options = [
        fetch_options: fetch_options(),
        write_options: [backend: RecordingBackend, recipient: self()],
        publish_options: publish_options(:ok)
      ]

      assert {:ok, %{request_id: request_id}} = AgencyRecorder.record(@settings, options)
      assert RequestId.valid?(request_id)
    end

    test "logs the destination at info" do
      log =
        capture_log([level: :info, metadata: [:destination]], fn ->
          assert {:ok, _recorded} = record()
        end)

      assert log =~ "[info]"
      assert log =~ "OneBusAway agency response recorded"
      assert log =~ "destination=raw/oba/agencies-with-coverage/dt=2026-10-02/"
    end
  end

  describe "record/2 fetch failures" do
    for {name, arrange, reason} <- [
          {"a 500 response", {:fixture, "server_error", 500}, {:http_status, 500}},
          {"a 401 response", {:fixture, "unauthorized", 401}, {:http_status, 401}},
          {"a 404 response", {:body, "", 404}, {:http_status, 404}},
          {"an API-level error on HTTP 200", {:fixture, "api_error", 200},
           {:api_error, %{code: 400, text: "invalid parameter"}}},
          {"a body that is not JSON", {:body, "<html>not json", 200}, :invalid_json},
          {"a redirect", {:body, "", 302}, {:unexpected_redirect, 302}},
          {"a transport fault", :timeout, {:transport, :timeout}}
        ] do
      test "returns the fetch error and writes nothing for #{name}" do
        case unquote(Macro.escape(arrange)) do
          {:fixture, fixture_name, status} -> stub_fixture(fixture_name, status)
          {:body, body, status} -> stub_body(body, status)
          :timeout -> Req.Test.stub(@stub_name, &Req.Test.transport_error(&1, :timeout))
        end

        assert record() == {:error, {:fetch, unquote(Macro.escape(reason))}}
        refute_received {:written, _request}
        refute_received {:published, _records}
      end
    end

    for fixture_name <- [
          "agencies_with_coverage_schema_violation",
          "agencies_with_coverage_unreferenced",
          "agencies_with_coverage_limit_exceeded"
        ] do
      test "raises and writes nothing for the malformed payload #{fixture_name}" do
        stub_fixture(unquote(fixture_name))

        assert_raise AssertionError, fn -> record() end
        refute_received {:written, _request}
      end
    end

    test "logs the failed stage at error" do
      stub_fixture("server_error", 500)

      log =
        capture_log([metadata: [:stage, :request_id]], fn ->
          assert {:error, {:fetch, _reason}} = record()
        end)

      assert log =~ "[error]"
      assert log =~ "OneBusAway agency response not recorded"
      assert log =~ "stage=fetch"
      assert log =~ "request_id=#{@request_id}"
    end
  end

  describe "record/2 write failures" do
    setup do
      stub_fixture("agencies_with_coverage")
      :ok
    end

    for reason <- [:storage_full, :already_exists, {:invalid_destination, :redirected}] do
      test "returns the writer error #{inspect(reason)}" do
        write_options = [
          backend: RefusingBackend,
          recipient: self(),
          reason: unquote(Macro.escape(reason))
        ]

        assert record(write_options: write_options) ==
                 {:error, {:write, unquote(Macro.escape(reason))}}

        refute_received {:published, _records}
      end
    end

    test "logs the failed stage at error" do
      write_options = [backend: RefusingBackend, recipient: self(), reason: :storage_full]

      log =
        capture_log([metadata: [:stage]], fn ->
          assert {:error, {:write, :storage_full}} = record(write_options: write_options)
        end)

      assert log =~ "[error]"
      assert log =~ "stage=write"
    end
  end

  describe "record/2 response stored event" do
    setup do
      stub_fixture("agencies_with_coverage")
      :ok
    end

    test "publishes one event after the write, naming what it stored" do
      assert {:ok, recorded} = record()

      assert_received {:written, _request}
      assert_received {:published, [%{value: value}]}
      assert {:ok, decoded} = StoredEvent.decode(value)
      assert Map.delete(decoded, :event_id) == recorded
      refute_received {:published, _records}
    end

    test "publishes the event to the dataset's event topic under the dataset's key" do
      assert {:ok, _recorded} = record()

      assert_received {:published, [record]}
      assert record.topic == "oba.agencies-with-coverage.response-stored"
      assert record.key == "oba/agencies-with-coverage"
    end

    test "gives the event its identifier, the recorder as source, and the fetch time" do
      assert {:ok, _recorded} = record()

      assert_received {:published, [%{value: value}]}

      assert %{
               "id" => @event_id,
               "source" => "/gobusgo/recorder/oba/agencies-with-coverage",
               "time" => "2026-10-02T03:15:00Z"
             } = JSON.decode!(value)
    end

    test "generates an event identifier when none is given" do
      options = [
        request_id: @request_id,
        fetch_options: fetch_options(),
        write_options: [backend: RecordingBackend, recipient: self()],
        publish_options: publish_options(:ok)
      ]

      assert {:ok, _recorded} = AgencyRecorder.record(@settings, options)

      assert_received {:published, [%{value: value}]}
      assert RequestId.valid?(JSON.decode!(value)["id"])
    end

    for reason <- [:timeout, :unavailable, :unknown_topic, :record_too_large] do
      test "returns the recording when the publish fails with #{reason}" do
        publish_options = publish_options({:error, unquote(reason)})

        assert {:ok, %{destination: destination}} = record(publish_options: publish_options)
        assert_received {:written, %{destination: ^destination}}
      end
    end

    test "logs a recording without its event once, as a warning with the reason" do
      log =
        capture_log([metadata: :all], fn ->
          assert {:ok, _recorded} = record(publish_options: publish_options({:error, :timeout}))
        end)

      assert log =~ "[warning] OneBusAway agency response recorded without its event"
      assert log =~ "reason=:timeout"
      assert log =~ "request_id=#{@request_id}"
      refute log =~ "[info] OneBusAway agency response recorded"
    end
  end

  describe "record/2 credential hygiene" do
    test "stores no key when the server echoes it in the data" do
      body =
        "agencies_with_coverage"
        |> fixture()
        |> String.replace("Metro Transit", "Metro #{@api_key}")

      stub_body(body)

      assert {:ok, _recorded} = record()
      assert_received {:written, %{destination: destination, content: stored}}
      refute destination =~ @api_key
      refute :zlib.gunzip(stored) =~ @api_key
    end

    test "stores an agency link that carries a key parameter" do
      body =
        "agencies_with_coverage"
        |> fixture()
        |> String.replace("https://metro.example.test", "https://metro.example.test/?key=x")

      stub_body(body)

      assert {:ok, _recorded} = record()
      assert_received {:written, %{content: stored}}
      assert :zlib.gunzip(stored) =~ "https://metro.example.test/?key=x"
    end

    test "returns and logs no key when the server echoes it in an error" do
      stub_body(~s({"code": 400, "currentTime": 1, "text": "bad key #{@api_key}", "version": 2}))

      log =
        capture_log([metadata: :all], fn ->
          refute inspect(record(), limit: :infinity) =~ @api_key
        end)

      refute log =~ @api_key
    end
  end
end
