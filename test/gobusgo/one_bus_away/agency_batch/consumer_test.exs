defmodule Gobusgo.OneBusAway.AgencyBatch.ConsumerTest do
  # Hands consume/2 the values of "response stored" records, as a publisher
  # backend does, with reader and publisher doubles defined here. What was
  # processed is observed through the records the publisher double receives.
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.AgencyBatch.Consumer
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.OneBusAway.RawAgencyResponse.StoredEvent
  alias Gobusgo.Publisher

  @moduletag capture_log: true

  defmodule StoredContent do
    @behaviour Gobusgo.Reader

    @impl Gobusgo.Reader
    def read(destination, options) do
      case Keyword.fetch!(options, :stored) do
        %{^destination => content} -> {:ok, content}
        _other -> {:error, :not_found}
      end
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

  @event_id "0199c4a2-7e1b-7a3f-9d20-0000000000ff"

  # The stored response of a fetch with one agency, named by `index`.
  defp raw(index) do
    id = Integer.to_string(index)

    envelope = %{
      "code" => 200,
      "currentTime" => 1_710_953_797_130,
      "data" => %{
        "limitExceeded" => false,
        "list" => [
          %{
            "agencyId" => id,
            "lat" => 47.5,
            "lon" => -122.25,
            "latSpan" => 0.5,
            "lonSpan" => 0.75
          }
        ],
        "references" => %{
          "agencies" => [
            %{
              "id" => id,
              "name" => "Agency #{id}",
              "url" => "https://agency.example.test",
              "timezone" => "America/Los_Angeles"
            }
          ]
        }
      },
      "text" => "OK",
      "version" => 2
    }

    response = %{
      agencies: [],
      envelope: envelope,
      fetched_at: DateTime.add(~U[2026-10-02 03:15:00Z], index, :minute),
      host: "oba.example.test",
      http_status: 200,
      method: "GET"
    }

    request_id = "0199c4a2-7e1b-7a3f-9d20-#{String.pad_leading(id, 12, "0")}"
    built = RawAgencyResponse.build(%{response: response, request_id: request_id})
    Map.put(built, :request_id, request_id)
  end

  defp event(raw) do
    record =
      StoredEvent.record(%{
        event_id: @event_id,
        source: "/gobusgo/test/oba/agencies-with-coverage",
        time: raw.fetched_at,
        response: Map.take(raw, [:destination, :fetched_at, :data_sha256, :request_id])
      })

    record.value
  end

  defp consume(raws, values) do
    Consumer.consume(
      [
        read_options: [
          backend: StoredContent,
          stored: Map.new(raws, &{&1.destination, &1.content})
        ],
        publish_options: [backend: RecordingPublisher, recipient: self()]
      ],
      values
    )
  end

  # The agency identifiers of the manifests published so far, in order.
  defp published_manifests do
    receive do
      {:published, [%{key: "manifest", value: value}]} ->
        [JSON.decode!(value)["data"]["agencyIds"] | published_manifests()]

      {:published, _agency_records} ->
        published_manifests()
    after
      0 -> []
    end
  end

  describe "consume/2" do
    test "processes the stored response an event names" do
      raw = raw(1)

      assert consume([raw], [event(raw)]) == :ok

      assert published_manifests() == [["1"]]
    end

    test "processes the events in order" do
      raws = [raw(1), raw(2), raw(3)]

      assert consume(raws, Enum.map(raws, &event/1)) == :ok

      assert published_manifests() == [["1"], ["2"], ["3"]]
    end

    test "returns ok and goes on to the next event when a stored response fails" do
      [missing, present] = [raw(1), raw(2)]

      assert consume([present], [event(missing), event(present)]) == :ok

      assert published_manifests() == [["2"]]
    end

    test "skips a value that is not a response stored event" do
      raw = raw(1)

      assert consume([raw], ["{not json", "{}", event(raw)]) == :ok

      assert published_manifests() == [["1"]]
    end

    test "logs the skipped values once, as a warning with their count" do
      raw = raw(1)

      log =
        capture_log([metadata: :all], fn ->
          consume([raw], ["{not json", event(raw), "{}"])
        end)

      assert log =~ "[warning] Agency batch consumer skipped invalid events"
      assert log =~ "invalid_count=2"
    end

    test "logs no warning when every value is an event" do
      raw = raw(1)

      log = capture_log([level: :warning], fn -> consume([raw], [event(raw)]) end)

      refute log =~ "skipped invalid events"
    end

    test "logs a stored response that fails to process once, at error with its stage" do
      raw = raw(1)

      log = capture_log([metadata: :all], fn -> consume([], [event(raw)]) end)

      assert log =~ "[error] Agency batch consumer failed"
      assert log =~ "destination=#{raw.destination}"
      assert log =~ "stage=read"
      assert log =~ "error_code=READ_FAILURE"
    end

    test "refuses more values than one publisher call holds" do
      values = List.duplicate("{}", Publisher.record_count_max() + 1)

      assert_raise AssertionError, fn -> consume([], values) end
    end
  end
end
