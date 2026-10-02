# Kafka integration

Kafka is the event bus between storing a raw response and processing it, and the data store for processed records (decisions on GOB-43, GOB-47, GOB-48, and GOB-49 in Linear). The application talks to it through two libraries: brod 4.7 produces and reads topics without a consumer group, and BroadwayKafka 0.7 consumes as a consumer group. Both are verified against Apache Kafka 4.3.1, the local broker's image: producing with headers and gzip, reading a topic from its earliest record, consumer group offset commits, and the error values below (checked 2026-10-02).

## Documentation sources

The modules follow the library source in `deps/`, which is the version actually built; the comments there document every option. The source was read on 2026-10-02; the links below name where it is published and were not fetched.

- brod: https://github.com/kafka4beam/brod — `src/brod.erl` (client and producer options), `src/brod_producer.erl` (producer options and defaults), `src/brod_topic_subscriber.erl`.
- BroadwayKafka: https://hexdocs.pm/broadway_kafka/BroadwayKafka.Producer.html — `lib/broadway_kafka/producer_options.ex` lists every option and default.
- Kafka topic configuration: https://kafka.apache.org/41/configuration/topic-configs/

## Modules

- `Gobusgo.Kafka.Client.start/1` registers one brod client under brod's own supervisor. The application starts it as `Gobusgo.Kafka.Client` with the endpoints from `GOBUSGO_KAFKA_BOOTSTRAP_SERVERS`. Topic auto-creation is off in every request.
- `Gobusgo.Publisher.Kafka` is the publisher backend. It starts a producer per topic on first use with the settings from GOB-43 (all in-sync replicas acknowledge, gzip, one request in flight per partition, three retries), sends every record of a call before awaiting the acknowledgements, and bounds the call with a deadline. It rejects a record over 1,000,000 bytes before sending, because brod's producer process crashes on the broker's `message_too_large`.
- `Gobusgo.Kafka.TopicSubscriber` reads one topic without a consumer group and feeds a `{module, function, arguments}`. It restarts its brod subscriber after a delay when it stops, and stops the client's partition consumers of the topic before each start so the new reader begins at the earliest record.
- `Gobusgo.OneBusAway.AgencyTrigger.KafkaConsumer` is the BroadwayKafka pipeline; its contract is in `lib/gobusgo/one_bus_away/AGENTS.md`. BroadwayKafka starts its own brod client per producer.

## Observed behavior

- **Unreachable broker.** `:brod.start_client/3` returns `:ok` at once; the client then stops and brod starts it again every `restart_delay_seconds` (10), and calls that name it return `{:error, :client_down}`, which the publisher reports as `:unavailable`. The application starts and serves HTTP without a broker; brod and BroadwayKafka log every failed reconnection.
- **Unknown topic.** Producing returns `{:error, :unknown_topic_or_partition}`, reported as `:unknown_topic`.
- **Unacknowledged Broadway message.** BroadwayKafka acknowledges every message whose handler returns, raises, or exits. A killed processor leaves its message unacknowledged, later offsets of the partition stay uncommitted, and the pipeline keeps running.
- **Consumer latency.** A BroadwayKafka poll fetches its assigned partitions one after another, and an empty partition holds its fetch open for `max_wait_time`. With the library's defaults (1,000 ms per partition, a poll every 2,000 ms) a record on a 12-partition topic waited about 8 seconds; the consumer sets 100 ms and 1,000 ms, and a recorded response reaches the view in about 3 seconds.
- **Group membership after an unclean stop.** A member that stops without leaving the group holds its partitions until its session timeout (30 seconds), so the first event after such a restart waits up to that long.

## Configuration and topics

`GOBUSGO_KAFKA_BOOTSTRAP_SERVERS` is a comma-separated `host:port` list, at most 16 entries, defaulting to `localhost:9092`. Kafka is off in the test environment. The application creates no topic; the README lists the commands that create the agency topics on the local broker. Tests tagged `kafka` read `GOBUSGO_TEST_KAFKA_BOOTSTRAP_SERVERS` and create and delete topics of their own.
