defmodule Gobusgo.OneBusAway.ResponseTriggerVehicleTest do
  # Drives handle/2 with the vehicle dataset's modules and with reader and
  # publisher doubles defined here, so the trigger is observed processing and
  # dead-lettering vehicle events through the reader and publisher contracts
  # with no storage and no broker. Delays are one millisecond.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.OneBusAway.RawVehicleResponse
  alias Gobusgo.OneBusAway.RawVehicleResponse.StoredEvent
  alias Gobusgo.OneBusAway.ResponseTrigger
  alias Gobusgo.OneBusAway.VehicleBatch

  @moduletag capture_log: true

  defmodule ScriptedReader do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(destination, options) do
      send(Keyword.fetch!(options, :recipient), {:read, destination})
      Keyword.fetch!(options, :read).(destination)
    end

    @impl Gobusgo.Reader
    def discover(_request, _options), do: {:ok, %{destinations: [], cursor: nil}}
  end

  defmodule RecordingPublisher do
    @behaviour Gobusgo.Publisher

    @impl Gobusgo.Publisher
    def publish(records, options) do
      send(Keyword.fetch!(options, :recipient), {:published, records})
      :ok
    end
  end

  @event_topic "oba.vehicles-for-agency.response-stored"
  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"

  setup do
    %{task_supervisor: start_supervised!(Task.Supervisor)}
  end

  defp raw do
    response = %{
      agency_id: "40",
      vehicles: [],
      envelope: %{
        "code" => 200,
        "currentTime" => 1_710_953_797_130,
        "data" => %{
          "limitExceeded" => false,
          "list" => [
            %{"vehicleId" => "40_a", "lastUpdateTime" => 0, "lastLocationUpdateTime" => 0}
          ]
        },
        "text" => "OK",
        "version" => 2
      },
      fetched_at: ~U[2026-10-02 03:15:00Z],
      host: "oba.example.test",
      http_status: 200,
      method: "GET"
    }

    RawVehicleResponse.build(%{response: response, request_id: @request_id})
  end

  defp consumed(raw) do
    record =
      StoredEvent.record(%{
        event_id: "0199c4a2-7e1b-7a3f-9d20-0000000000ff",
        source: "/gobusgo/test",
        time: raw.fetched_at,
        response:
          raw
          |> Map.take([:destination, :fetched_at, :data_sha256])
          |> Map.merge(%{agency_id: "40", request_id: @request_id})
      })

    record |> Map.take([:topic, :key, :value, :headers]) |> Map.merge(%{partition: 7, offset: 42})
  end

  defp handle(consumed, context, read) do
    ResponseTrigger.handle(consumed,
      event: StoredEvent,
      processor: VehicleBatch,
      consumer_group: "gobusgo.vehicle-processor",
      task_supervisor: context.task_supervisor,
      attempt_deadline_ms: 1_000,
      retry_delay_ms_base: 1,
      read_options: [backend: ScriptedReader, recipient: self(), read: read],
      publish_options: [backend: RecordingPublisher, recipient: self()]
    )
  end

  defp published do
    {:messages, messages} = Process.info(self(), :messages)
    for {:published, records} <- messages, record <- records, do: record
  end

  test "processes the stored vehicle response a vehicle event names", context do
    raw = raw()
    read = fn _destination -> {:ok, Gobusgo.Compression.compress(raw.content)} end

    assert handle(consumed(raw), context, read) == :processed

    assert Enum.map(published(), & &1.key) == ["vehicle/40/40_a", "manifest/40"]
  end

  test "dead-letters a vehicle event after three failed attempts, the failure in headers",
       context do
    consumed = consumed(raw())
    read = fn _destination -> {:error, :io_failure} end

    log = capture_log(fn -> assert handle(consumed, context, read) == :dead_lettered end)

    assert [dead_letter] = published()
    assert dead_letter.topic == @event_topic <> ".dead-letter"
    assert dead_letter.key == "oba/vehicles-for-agency/40"
    assert dead_letter.value == consumed.value

    assert %{
             "ERROR_CODE" => "READ_FAILURE",
             "RETRY_ATTEMPTS" => "3",
             "EXHAUSTED_RETRY_CONDITION" => "MaximumRetryAttempts",
             "ORIGINAL_TOPIC" => @event_topic,
             "CONSUMER_GROUP" => "gobusgo.vehicle-processor"
           } = Map.new(dead_letter.headers)

    assert log =~ "Response trigger dead-lettered"
  end

  test "dead-letters an agency event at once, as an event of another dataset", context do
    agency_event =
      Gobusgo.OneBusAway.RawAgencyResponse.StoredEvent.record(%{
        event_id: "0199c4a2-7e1b-7a3f-9d20-0000000000ff",
        source: "/gobusgo/test",
        time: ~U[2026-10-02 03:15:00Z],
        response: %{
          destination: "raw/oba/agencies-with-coverage/dt=2026-10-02/file.json.gz",
          fetched_at: ~U[2026-10-02 03:15:00Z],
          data_sha256: String.duplicate("ab", 32),
          request_id: @request_id
        }
      })

    consumed = %{consumed(raw()) | value: agency_event.value}

    assert handle(consumed, context, fn _destination -> {:error, :not_found} end) ==
             :dead_lettered

    refute_received {:read, _destination}
    assert [%{headers: headers}] = published()
    assert Map.new(headers)["ERROR_CODE"] == "SCHEMA_MISMATCH"
  end
end
