defmodule Gobusgo.OneBusAway.ArrivalFlowBrokerTest do
  # Runs the arrivals dataset from its "response stored" event to its view
  # against a real broker: the event is published to an event topic created
  # for the test, the consumer pipeline processes the stored response, and a
  # topic subscriber feeds the processed record to a fetch view, which the
  # test reads. The reader is a double defined here, so no storage is
  # involved, and the publisher double sends the processed record to a state
  # topic created for the test, so the dataset's own topic is left alone.
  use ExUnit.Case, async: true

  alias Gobusgo.Kafka.TopicSubscriber
  alias Gobusgo.OneBusAway.ArrivalBatch
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RawArrivalResponse
  alias Gobusgo.OneBusAway.RawArrivalResponse.StoredEvent
  alias Gobusgo.OneBusAway.ResponseTrigger.KafkaConsumer
  alias Gobusgo.Publisher
  alias Gobusgo.Test.KafkaBroker

  @moduletag :kafka
  @moduletag capture_log: true
  @moduletag timeout: 120_000

  defmodule StoredReader do
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

  defmodule RetargetingPublisher do
    @behaviour Gobusgo.Publisher

    # A dead-letter record keeps its topic; a processed record, whose topic
    # is fixed, goes to the state topic of the test.
    @impl Gobusgo.Publisher
    def publish(records, options) do
      state_topic = Keyword.fetch!(options, :state_topic)

      records =
        for %{topic: topic} = record <- records do
          if String.ends_with?(topic, ".dead-letter") do
            record
          else
            %{record | topic: state_topic}
          end
        end

      Publisher.Kafka.publish(records, client: Keyword.fetch!(options, :client))
    end
  end

  @fixture_path Path.expand(
                  "../../fixtures/one_bus_away/arrivals_and_departures_for_stop.json",
                  __DIR__
                )
  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @fetched_at ~U[2026-10-05 01:17:31Z]
  @fetch_age_ms_max 40 * 60 * 1_000
  @stop_id "95_7"
  @switch_timeout_ms 60_000

  defp stored do
    RawArrivalResponse.build(%{
      request_id: @request_id,
      response: %{
        stop_id: @stop_id,
        arrivals: nil,
        envelope: @fixture_path |> File.read!() |> JSON.decode!(),
        fetched_at: @fetched_at,
        host: "oba.example.test",
        http_status: 200,
        method: "GET"
      }
    })
  end

  defp event_record(topic, stored) do
    record =
      StoredEvent.record(%{
        event_id: Gobusgo.RequestId.generate(),
        source: "/gobusgo/test/oba/arrivals-and-departures-for-stop",
        time: DateTime.add(@fetched_at, 1, :second),
        response: %{
          stop_id: @stop_id,
          destination: stored.destination,
          fetched_at: stored.fetched_at,
          data_sha256: stored.data_sha256,
          request_id: @request_id
        }
      })

    %{record | topic: topic}
  end

  setup do
    client = KafkaBroker.start_client()
    event_topic = KafkaBroker.create_topic("arrival-events")
    dead_letter_topic = KafkaBroker.create_topic_named(event_topic <> ".dead-letter")
    state_topic = KafkaBroker.create_topic("arrival-state")
    unique = "#{System.unique_integer([:positive])}-#{System.os_time(:millisecond)}"
    group = "test-group-#{unique}"
    view = Module.concat(__MODULE__, "View#{unique}")
    stored = stored()

    start_supervised!(
      {FetchView,
       name: view,
       pubsub: Gobusgo.PubSub,
       records: ArrivalBatch.Records,
       id_count_max: 1,
       fetch_age_ms_max: @fetch_age_ms_max,
       clock: fn -> DateTime.add(@fetched_at, 1, :minute) end}
    )

    :ok = FetchView.subscribe(%{view: view, pubsub: Gobusgo.PubSub})

    start_supervised!(
      {TopicSubscriber,
       name: Module.concat(__MODULE__, "Subscriber#{unique}"),
       client: client,
       topic: state_topic,
       subscriber: {FetchView, :apply_records, [view]},
       restart_delay_ms: 50}
    )

    start_supervised!(
      {KafkaConsumer,
       event: StoredEvent,
       processor: ArrivalBatch,
       name: Module.concat(__MODULE__, "Consumer#{unique}"),
       producer:
         KafkaConsumer.producer(%{
           endpoints: KafkaBroker.endpoints(),
           consumer_group: group,
           topic: event_topic
         }),
       consumer_group: group,
       task_supervisor: start_supervised!(Task.Supervisor),
       retry_delay_ms_base: 1,
       read_options: [
         backend: StoredReader,
         stored: %{stored.destination => Gobusgo.Compression.compress(stored.content)}
       ],
       publish_options: [backend: RetargetingPublisher, client: client, state_topic: state_topic]}
    )

    %{
      client: client,
      event_topic: event_topic,
      dead_letter_topic: dead_letter_topic,
      view: view,
      stored: stored
    }
  end

  test "a stored response's event puts the stop's arrivals in the view", context do
    :ok =
      Publisher.publish([event_record(context.event_topic, context.stored)],
        backend: Publisher.Kafka,
        client: context.client
      )

    view = context.view
    assert_receive {:fetch_view_switched, ^view}, @switch_timeout_ms

    assert %{id: @stop_id, request_id: @request_id, fetched_at: @fetched_at, arrivals: arrivals} =
             FetchView.current_fetch(view, @stop_id)

    assert length(arrivals) == 4
    assert KafkaBroker.messages(context.dead_letter_topic) == []
  end
end
