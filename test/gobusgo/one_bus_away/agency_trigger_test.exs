defmodule Gobusgo.OneBusAway.AgencyTriggerTest do
  # Drives handle/2 with consumed records built by StoredEvent.record/1 and
  # with reader and publisher doubles defined here, so processing, retries,
  # and dead-lettering are observed through the reader and publisher
  # contracts with no storage and no broker. Delays are one millisecond.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.OneBusAway.AgencyTrigger
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.OneBusAway.RawAgencyResponse.StoredEvent

  @moduletag capture_log: true

  defmodule ScriptedReader do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(destination, options) do
      recipient = Keyword.fetch!(options, :recipient)
      send(recipient, {:read, destination})
      Keyword.fetch!(options, :read).(destination)
    end

    @impl Gobusgo.Reader
    def discover(_request, _options), do: {:ok, %{destinations: [], cursor: nil}}
  end

  defmodule ScriptedPublisher do
    @behaviour Gobusgo.Publisher

    @impl Gobusgo.Publisher
    def publish(records, options) do
      send(Keyword.fetch!(options, :recipient), {:published, records})
      Keyword.fetch!(options, :publish).(records)
    end
  end

  @event_topic "oba.agencies-with-coverage.response-stored"
  @dead_letter_topic @event_topic <> ".dead-letter"
  @state_topic "oba.agencies-with-coverage.state"
  @consumer_group "test-group"
  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @event_id "0199c4a2-7e1b-7a3f-9d20-0000000000ff"
  @fetched_at ~U[2026-10-02 03:15:00Z]

  setup do
    %{task_supervisor: start_supervised!(Task.Supervisor)}
  end

  defp raw do
    data = %{
      "limitExceeded" => false,
      "list" => [
        %{"agencyId" => "1", "lat" => 47.5, "lon" => -122.25, "latSpan" => 0.5, "lonSpan" => 0.75}
      ],
      "references" => %{
        "agencies" => [
          %{
            "id" => "1",
            "name" => "Metro Transit",
            "url" => "https://agency.example.test",
            "timezone" => "America/Los_Angeles"
          }
        ]
      }
    }

    response = %{
      agencies: [],
      envelope: %{
        "code" => 200,
        "currentTime" => 1_710_953_797_130,
        "data" => data,
        "text" => "OK",
        "version" => 2
      },
      fetched_at: @fetched_at,
      host: "oba.example.test",
      http_status: 200,
      method: "GET"
    }

    RawAgencyResponse.build(%{response: response, request_id: @request_id})
  end

  defp consumed(raw) do
    record =
      StoredEvent.record(%{
        event_id: @event_id,
        source: "/gobusgo/test/oba/agencies-with-coverage",
        time: ~U[2026-10-02 03:15:01Z],
        response:
          Map.put(
            Map.take(raw, [:destination, :fetched_at, :data_sha256]),
            :request_id,
            @request_id
          )
      })

    record |> Map.take([:topic, :key, :value, :headers]) |> Map.merge(%{partition: 7, offset: 42})
  end

  defp handle(consumed, context, overrides \\ []) do
    read = Keyword.get(overrides, :read, fn _destination -> {:ok, raw().content} end)
    publish = Keyword.get(overrides, :publish, fn _records -> :ok end)

    AgencyTrigger.handle(consumed,
      consumer_group: @consumer_group,
      task_supervisor: context.task_supervisor,
      attempt_deadline_ms: Keyword.get(overrides, :attempt_deadline_ms, 1_000),
      retry_delay_ms_base: 1,
      read_options: [backend: ScriptedReader, recipient: self(), read: read],
      publish_options: [backend: ScriptedPublisher, recipient: self(), publish: publish]
    )
  end

  defp published_topics do
    {:messages, messages} = Process.info(self(), :messages)
    for {:published, [%{topic: topic} | _rest]} <- messages, do: topic
  end

  defp read_count do
    {:messages, messages} = Process.info(self(), :messages)
    Enum.count(messages, &match?({:read, _destination}, &1))
  end

  defp dead_letter do
    {:messages, messages} = Process.info(self(), :messages)
    [record] = for {:published, [%{topic: @dead_letter_topic} = record]} <- messages, do: record
    %{record: record, headers: Map.new(record.headers)}
  end

  describe "handle/2 processing" do
    test "publishes the agencies and the manifest of the response the event names", context do
      assert handle(consumed(raw()), context) == :processed

      assert_received {:read, destination}
      assert destination == raw().destination
      assert published_topics() == [@state_topic, @state_topic]
    end

    test "reads once and dead-letters nothing for a response that processes", context do
      assert handle(consumed(raw()), context) == :processed

      assert read_count() == 1
      refute @dead_letter_topic in published_topics()
    end
  end

  describe "handle/2 events that are not response stored events" do
    test "dead-letters a value that is not JSON untouched, without reading", context do
      consumed = %{consumed(raw()) | value: "<html>"}

      assert handle(consumed, context) == :dead_lettered

      assert read_count() == 0
      assert %{record: %{value: "<html>", key: key}, headers: headers} = dead_letter()
      assert key == consumed.key
      assert headers["ERROR_CODE"] == "INVALID_JSON"
      assert headers["RETRY_ATTEMPTS"] == "1"
      refute Map.has_key?(headers, "EXHAUSTED_RETRY_CONDITION")
    end

    test "dead-letters an event of an unsupported type", context do
      value = String.replace(consumed(raw()).value, "response.stored.v1", "response.stored.v9")

      assert handle(%{consumed(raw()) | value: value}, context) == :dead_lettered
      assert dead_letter().headers["ERROR_CODE"] == "UNSUPPORTED_TYPE"
    end
  end

  describe "handle/2 failures" do
    test "dead-letters a permanent failure after one attempt", context do
      read = fn _destination -> {:error, :not_found} end

      assert handle(consumed(raw()), context, read: read) == :dead_lettered

      assert read_count() == 1
      assert %{headers: headers} = dead_letter()
      assert headers["ERROR_CODE"] == "READ_FAILURE"
      assert headers["RETRY_ATTEMPTS"] == "1"
      refute Map.has_key?(headers, "EXHAUSTED_RETRY_CONDITION")
    end

    test "retries a transient failure and dead-letters it after the third attempt", context do
      read = fn _destination -> {:error, :io_failure} end

      assert handle(consumed(raw()), context, read: read) == :dead_lettered

      assert read_count() == 3
      assert %{headers: headers} = dead_letter()
      assert headers["ERROR_CODE"] == "READ_FAILURE"
      assert headers["RETRY_ATTEMPTS"] == "3"
      assert headers["EXHAUSTED_RETRY_CONDITION"] == "MaximumRetryAttempts"
    end

    test "names where the record was consumed and who gave up", context do
      read = fn _destination -> {:error, :not_found} end

      assert handle(consumed(raw()), context, read: read) == :dead_lettered

      assert %{
               "ORIGINAL_TOPIC" => @event_topic,
               "ORIGINAL_PARTITION" => "7",
               "ORIGINAL_OFFSET" => "42",
               "CONSUMER_GROUP" => @consumer_group
             } = dead_letter().headers
    end

    test "processes a response whose transient failure clears on a retry", context do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      read = fn _destination ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {:error, :io_failure}
          _later -> {:ok, raw().content}
        end
      end

      assert handle(consumed(raw()), context, read: read) == :processed

      assert read_count() == 2
      assert published_topics() == [@state_topic, @state_topic]
    end

    test "dead-letters as TIMEOUT when every attempt runs past its deadline", context do
      read = fn _destination -> Process.sleep(:infinity) end

      assert handle(consumed(raw()), context, read: read, attempt_deadline_ms: 10) ==
               :dead_lettered

      assert read_count() == 3
      assert dead_letter().headers["ERROR_CODE"] == "TIMEOUT"
    end

    test "dead-letters as INTERNAL_ERROR when every attempt crashes", context do
      read = fn _destination -> raise "boom" end

      assert handle(consumed(raw()), context, read: read) == :dead_lettered

      assert read_count() == 3
      assert dead_letter().headers["ERROR_CODE"] == "INTERNAL_ERROR"
    end

    test "publishes no manifest when the agency records are not acknowledged", context do
      publish = fn
        [%{topic: @state_topic} | _rest] -> {:error, :timeout}
        [%{topic: @dead_letter_topic}] -> :ok
      end

      assert handle(consumed(raw()), context, publish: publish) == :dead_lettered

      {:messages, messages} = Process.info(self(), :messages)
      refute Enum.any?(messages, &match?({:published, [%{key: "manifest"}]}, &1))
      assert dead_letter().headers["ERROR_CODE"] == "WRITE_FAILURE"
    end
  end

  describe "handle/2 when the dead-letter record is not acknowledged" do
    test "returns the publisher's reason after three tries", context do
      read = fn _destination -> {:error, :not_found} end
      publish = fn _records -> {:error, :unavailable} end

      assert handle(consumed(raw()), context, read: read, publish: publish) ==
               {:error, {:dead_letter_unpublished, :unavailable}}

      assert published_topics() == List.duplicate(@dead_letter_topic, 3)
    end
  end

  describe "handle/2 logging" do
    # Log capture also sees the lines of tests running in other modules, so
    # each assertion reads only the entries that name this module's event.
    defp event_entries(log) do
      log |> String.split("\n\n") |> Enum.filter(&(&1 =~ "event_id=#{@event_id}"))
    end

    test "logs a dead-lettered record once at error, with its code and position", context do
      read = fn _destination -> {:error, :io_failure} end

      log =
        capture_log([metadata: :all], fn ->
          assert handle(consumed(raw()), context, read: read) == :dead_lettered
        end)

      assert [entry] = event_entries(log)
      assert entry =~ "[error]"
      assert entry =~ "Agency trigger dead-lettered"
      assert entry =~ "error_code=READ_FAILURE"
      assert entry =~ "attempt_count=3"
      assert entry =~ "partition=7"
      assert entry =~ "offset=42"
    end

    test "logs a response that processed after a retry at warning", context do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      read = fn _destination ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {:error, :io_failure}
          _later -> {:ok, raw().content}
        end
      end

      log =
        capture_log([metadata: :all], fn ->
          assert handle(consumed(raw()), context, read: read) == :processed
        end)

      assert [entry] = event_entries(log)
      assert entry =~ "[warning]"
      assert entry =~ "Agency trigger processed after retries"
      assert entry =~ "attempt_count=2"
    end

    test "logs an unpublished dead-letter record at error", context do
      read = fn _destination -> {:error, :not_found} end
      publish = fn _records -> {:error, :unavailable} end

      log =
        capture_log([metadata: :all], fn ->
          handle(consumed(raw()), context, read: read, publish: publish)
        end)

      assert [entry] = event_entries(log)
      assert entry =~ "[error]"
      assert entry =~ "Agency trigger dead letter not published"
      assert entry =~ "reason=:unavailable"
    end
  end
end
