# OneBusAway integration (Puget Sound / Sound Transit)

OneBusAway (OBA) is an open-source transit API. Gobusgo reads the Puget Sound deployment, which serves Sound Transit and the other regional agencies, through agency discovery via `agencies-with-coverage` and the active vehicles of each agency via `vehicles-for-agency`. Stop, route, and arrival methods are listed below for future work and are out of scope until implemented.

## Documentation sources

All links checked 2026-10-01.

- Method index: https://developer.onebusaway.org/api/where/methods
- REST conventions, envelope, response codes, references: https://developer.onebusaway.org/api/where
- `agencies-with-coverage`: https://developer.onebusaway.org/api/where/methods/agencies-with-coverage
- API key process: https://www.soundtransit.org/help-contacts/business-information/open-transit-data-otd
- `vehicles-for-agency`: https://developer.onebusaway.org/api/where/methods/vehicles-for-agency — checked 2026-10-02
- Trip status element: https://developer.onebusaway.org/api/where/elements/trip-status — checked 2026-10-02

## Server and credentials

The documentation host (`developer.onebusaway.org`) serves docs only; it is not the API server. The Puget Sound API server is `https://api.pugetsound.onebusaway.org`, taken from the example request in the `agencies-with-coverage` documentation (checked 2026-10-01). Authenticated calls with the project's issued key on 2026-10-02 succeeded: `agencies-with-coverage` returned 12 agencies, Sound Transit (`40`) and King County Metro (`1`) among them, and `vehicles-for-agency` returned HTTP 200 for each of them.

Key process, per Sound Transit: email `oba_api_key@soundtransit.org` with the contact's first and last name, an email address if different from the sender, and acknowledgment of the Transit Data Terms of Use. Sound Transit states processing takes 20 business days. The project's key is issued.

Every request carries the `key` query parameter. The key is read from configuration at runtime (environment variable `ONEBUSAWAY_API_KEY`) and never committed, logged, or written to documentation. The documentation's `key=TEST` example value is not a credential for this project.

Because the key travels in the query string, the HTTP client must redact `key` from URLs in serialized errors and logs. The AGENTS.md rule on stripping auth headers on cross-origin redirects does not apply to a query-string key; instead, do not follow redirects to a different origin, so the key never reaches an origin this integration did not name.

## Request conventions

- Format is chosen by path extension; always request `.json` (for example `/api/where/agencies-with-coverage.json`) and set the expected response type to JSON explicitly.
- `includeReferences=true|false` toggles the `references` section; leave it at the default `true` for discovery.
- Documented statuses (200, 400, 401, 404, 500, below) are accepted as data and branched on explicitly.

## Response envelope

Every response wraps its payload in:

| Field | Meaning |
| --- | --- |
| `version` | Response version; the `agencies-with-coverage` example shows `2` |
| `code` | Machine-readable response code |
| `text` | Human-readable description of `code` |
| `currentTime` | Server time, milliseconds since Unix epoch |
| `data` | Payload, with an optional `references` section |

Documented response codes:

| Code | Meaning | Handling |
| --- | --- | --- |
| 200 | Success | Parse `data` against the schema |
| 400 | Invalid request parameter | Return as a known outcome; a caller bug |
| 401 | Missing or invalid application key | Return as a known outcome; configuration problem, not retryable |
| 404 | Resource not found | Return as a known outcome |
| 500 | Service exception | Transient; retry with bounded backoff per the retry rules |

Documented codes return to the caller as values (a discriminated union); network faults, undocumented statuses, and payloads failing schema validation throw. The OBA docs do not state whether `code` in the body always equals the HTTP status; the integration should assert they match and treat a mismatch as malformed. Whether the docs mention a `Retry-After` header or rate-limit status is unverified; none was found.

## Reference resolution

`data.references` is a dictionary of objects that the main payload refers to by id: agencies, routes, stops, trips, and situations, in that order. Entries in `data.list` (or `data.entry`) hold ids, and the caller resolves them against the matching `references` collection. For agency discovery, `agencyId` resolves against `references.agencies[].id`. A `list` id with no matching reference is a malformed payload.

## Agency discovery: `agencies-with-coverage`

`GET /api/where/agencies-with-coverage.json?key=<key>`. The only documented parameter is `key`. The method is unpaginated; `data.limitExceeded` is `false` in the documented example, and its semantics are undocumented on the method page, so the requester should assert it is `false`.

Documented example response:

```json
{
  "code": 200,
  "currentTime": 1710953797130,
  "data": {
    "limitExceeded": false,
    "list": [
      { "agencyId": "1", "lat": 47.53009, "latSpan": 0.6819459999999964, "lon": -122.1462285, "lonSpan": 0.7207869999999872 }
    ],
    "references": {
      "agencies": [
        { "id": "1", "name": "Metro Transit", "url": "https://kingcounty.gov/en/dept/metro", "timezone": "America/Los_Angeles" }
      ]
    }
  },
  "text": "OK",
  "version": 2
}
```

Fields the first requester needs:

| Field | Type | Meaning |
| --- | --- | --- |
| `data.list[].agencyId` | string | Id; joins to `references.agencies[].id` |
| `data.list[].lat`, `lon` | number | Center of the coverage area |
| `data.list[].latSpan`, `lonSpan` | number | Height and width of the coverage bounding box |
| `data.references.agencies[].id` | string | Agency id |
| `data.references.agencies[].name` | string | Display name |
| `data.references.agencies[].url` | string | Agency website |
| `data.references.agencies[].timezone` | string | IANA timezone |

The example shows only these agency fields. The reference agency object may carry more fields (for example `lang`, `phone`, `disclaimer`) on the live server; unknown fields should be ignored rather than failing validation. Agency ids are server-assigned strings and may be prefixed or numeric; do not parse them.

Test requirements for the requester: a 200 fixture matching the example above; a list entry whose `agencyId` has no reference (malformed); a 401 body (missing or invalid key); a 500 body; a non-JSON or schema-violating payload (throws). Fixtures use placeholder keys only.

## Implementation

`Gobusgo.OneBusAway.Agencies.fetch/2` is the agency discovery requester and `Gobusgo.OneBusAway.Client.get/3` is the only module that issues HTTP requests. `Gobusgo.OneBusAway.Envelope.interpret/2` is the pure step every requester shares from an HTTP status and body to the decoded envelope or a documented failure. The client retries network faults and the statuses 408, 500, 502, 503, and 504 with a capped, jittered `retry_delay` (a custom delay function replaces Req's `Retry-After` handling, which suits an API that documents none), and sets `redirect: false`, `decode_body: false`, explicit timeouts, and a total deadline enforced around all attempts and every wait at the request gate. The key is passed via `params:` and scrubbed from every returned value. Returned errors: `{:transport, reason}`, `:deadline_exceeded`, `:rate_limited`, `{:http_status, status}`, `{:unexpected_redirect, status}`, `{:api_error, %{code: code, text: text}}`, `:invalid_json`. Schema violations, unreferenced agency ids, `limitExceeded: true`, and undocumented statuses raise `Gobusgo.Assert.AssertionError`.

`Gobusgo.OneBusAway.Agencies.fetch_response/2` makes the same request and returns the agencies together with the whole decoded envelope, the HTTP status, the method, the host, and the fetch time. The key is replaced wherever the server echoes it in the envelope, and the host is the host name alone, so no returned value carries a credential or a URL. Its `:clock` option supplies the fetch time.

`Gobusgo.OneBusAway.Agencies.parse/1` is the pure function from an envelope's `data` to the agencies. It returns a contract violation as a value: `{:schema_mismatch, mismatch}`, `{:agency_count_exceeded, count}`, or `{:unreferenced_agency, id}`. The requester raises on those values; a reader of stored responses handles them.

## Request gate

`Gobusgo.OneBusAway.RequestGate` owns the request budget of the API key. The application starts one, registered under the module's name, and `Client.get/3` takes a permit from it before every attempt, a retry included, and releases the permit with the attempt's outcome; its `:gate` option names another gate, which the tests use. `Gobusgo.OneBusAway.RequestGate.State` holds the rules and is pure. The gate never sees the key.

| Rule | Value | Meaning |
| --- | --- | --- |
| Refill interval | 100 ms | Ten permits a second; the bucket holds one token, so idle time buys no burst |
| In-flight cap | 4 | Permits held at one time |
| Waiter bound | 32 | Callers waiting for a permit, served in arrival order |
| Backoff window | 1,000 ms doubling to 60,000 ms | The pause after a 429 without `Retry-After`, jittered between half the window and all of it |
| `Retry-After` bound | 300,000 ms | The longest pause a response can name |

- A caller waits for a permit until 250 ms before its request's deadline. A caller whose wait runs out, or who arrives while 32 callers wait, gets `{:error, :rate_limited}`, which the requesters return unchanged.
- A 429 response pauses every caller, is returned as `{:error, {:http_status, 429}}`, and is never retried by the client. When the pause ends, one caller probes alone: a response that is not a 429 reopens the gate and resets the window, another 429 pauses again for a doubled window, and a probe that ends with no response lets the next caller probe.
- The gate monitors each caller, so a caller that exits or is killed at its deadline gives up its permit or its place among the waiters.
- State is in memory and per node: a restart begins open with a full bucket, and two running instances each spend a full budget.
- Logs: `warning` `OneBusAway request gate paused` with `pause_ms` and `pause_count`, and `info` `OneBusAway request gate reopened`.

The budget of ten requests per second is an assumption. OneBusAway documents neither a rate limit nor a 429 status nor `Retry-After` (https://developer.onebusaway.org/api/where — checked 2026-10-03); the gate treats a 429 as rate limiting on the project owner's statement that limits exist, and no 429 has been observed from the live server.

A new source needs no change here: its requests reach the gate through the client. A deadline shorter than the time its requests spend waiting for permits ends in `:rate_limited`, so a source that issues many requests per run sizes its deadline to 100 ms per request, plus the time the requests themselves take while four are in flight.

## Vehicles: `vehicles-for-agency`

`GET /api/where/vehicles-for-agency/<agency id>.json?key=<key>`. The agency identifier is the only documented parameter besides `key`, and the requester percent-encodes it into the path. The method is unpaginated and documents `data.limitExceeded` as "results were truncated", so the requester asserts it is `false`.

`Gobusgo.OneBusAway.Vehicles.fetch_response/2` takes the agency in its `:agency_id` option and returns the vehicles together with the whole decoded envelope, the agency, the HTTP status, the method, the host, and the fetch time, with the same key hygiene and errors as the agency requester. `Gobusgo.OneBusAway.Vehicles.parse/1` is the pure function from `data` to the vehicles, in the form `Gobusgo.OneBusAway.VehicleBatch.Records` publishes. It returns a contract violation as a value: `{:schema_mismatch, mismatch}`, `{:vehicle_count_exceeded, count}` above 5,000, `{:invalid_vehicle, index}` for an empty identifier or a time before zero, or `{:duplicate_vehicle, id}`. The requester raises on those values.

Shape of the live response, observed on 2026-10-02 across all 12 agencies (3,096 vehicles, the largest fetch King County Metro's 1,885, `limitExceeded` `false` throughout):

| Field | Where | Presence |
| --- | --- | --- |
| `vehicleId`, `tripId`, `lastUpdateTime`, `lastLocationUpdateTime`, `status`, `phase`, `occupancyCapacity`, `occupancyCount`, `occupancyStatus` | On the vehicle | Always. `tripId` is `""` when the vehicle serves no trip |
| `location` | On the vehicle | Exactly when `lastLocationUpdateTime` is not `0`, with or without a trip |
| `tripStatus` | On the vehicle | Only when the vehicle serves a trip; the key is absent otherwise, never `null` |
| `activeTripId`, `position`, `orientation`, `lastKnownOrientation`, `predicted`, `lastUpdateTime`, `lastLocationUpdateTime`, `serviceDate`, `scheduleDeviation`, stop and distance fields | In `tripStatus` | Always within a trip status |
| `lastKnownLocation` | In `tripStatus` | Exactly when the vehicle carries `location`, with the same value |

The mapping to the published vehicle follows from that table: `lastKnownLocation` comes from the vehicle's `location`, so a vehicle without a trip keeps its last report; `position`, `orientation`, `lastKnownOrientation`, `activeTripId`, and `predicted` come from `tripStatus` and are `null` without one; the two times come from the vehicle, and the trip status repeats them with the same values. `predicted` was `true` for every trip status, including trips whose vehicle had reported no location, and `lastKnownOrientation` was `0` for every vehicle without a reported location. A vehicle with only schedule data carries a block-derived identifier such as `40_H:121:0:Weekday:1:26SEP:52043:12345`; identifiers are opaque and never parsed. The response's `references` and `outOfRange` are kept in the envelope and not read.

Test fixtures under `test/fixtures/one_bus_away/vehicles_for_agency*.json` are cut from the live Sound Transit response, one vehicle for each combination of trip and reported location.

## Stored raw responses

`Gobusgo.OneBusAway.AgencyRecorder.record/2` calls `fetch_response/2` and passes the result through `Gobusgo.Writer.write/2`. It names no backend; application configuration selects one. `Gobusgo.OneBusAway.RawAgencyResponse.build/1` is the pure function that turns a response and a request identifier into the logical destination and the content.

What is stored: only an HTTP 200 response whose envelope `code` is 200 and whose `data` passes the requester's schema. Every other outcome returns `{:error, {:fetch, reason}}` or raises, and stores nothing. A writer failure returns `{:error, {:write, reason}}`. Writes are create-only, so every response is kept and none is replaced.

Logical destination:

```
raw/oba/agencies-with-coverage/dt=YYYY-MM-DD/<fetchedAt>_<requestId>_<dataHash12>.json
```

| Part | Meaning |
| --- | --- |
| `dt` | UTC date of the fetch time |
| `fetchedAt` | Fetch time, UTC basic ISO 8601 at second precision (`20261002T031500Z`) |
| `requestId` | UUID version 7 generated for the request (`Gobusgo.RequestId`) |
| `dataHash12` | First 12 characters of `meta.dataSha256` |

Content is one JSON object, `{"meta": ..., "body": ...}`, compact, with object keys sorted. `body` is the whole response envelope, re-encoded from the decoded response with no field removed, so the coverage list and the `references` section stay available. `meta`:

| Field | Meaning |
| --- | --- |
| `fetchedAt` | Fetch time, UTC extended ISO 8601 at second precision (`2026-10-02T03:15:00Z`); the same instant as in the destination |
| `host` | Host name of the server, without scheme, port, path, or credentials |
| `method` | HTTP method, `GET` |
| `httpStatus` | HTTP status, always `200` |
| `envelopeVersion` | The envelope's `version` |
| `envelopeCurrentTime` | The envelope's `currentTime`, milliseconds since the Unix epoch |
| `dataSha256` | Lowercase hexadecimal SHA-256 of `data`, encoded as compact JSON with sorted keys |
| `requestId` | The request identifier in the destination |

Reading a stored response back: `RawAgencyResponse.parse/1` returns the fetch time, the data hash, the request identifier, and the agencies. It rejects, as a value, content that is not the stored wrapper, data that does not hash to `meta.dataSha256`, a `meta` that names another destination, a request identifier that is not a UUID version 7, and agencies whose identifiers are empty or repeat. The hash covers `data` alone because `currentTime` differs on every response, so equal hashes mark responses with the same agencies.

Credentials: the URL is never stored. `RawAgencyResponse.build/1` raises when the destination or `meta` contains `key=`, and the recorder raises when the destination or the content contains the configured key. `body` is exempt from the `key=` check, because it holds text the agencies supply, such as a website link with a `key` parameter of its own.

The recorder logs one line per call: `info` `OneBusAway agency response recorded` with `destination`, `request_id`, `data_sha256`, and `content_bytes`; or `error` `OneBusAway agency response not recorded` with `stage` (`fetch` or `write`), `reason`, and `request_id`.

## Scheduled sources

`Gobusgo.OneBusAway.Sources.specs/2` returns one spec per source for `Gobusgo.Scheduler`: the name the scheduler is registered under, the function to run, the interval, and the deadline of one run. It is pure and starts nothing. The application starts a scheduler per spec when the OneBusAway settings are present, and none under test.

| Source | Scheduler name | Run | Interval | Deadline |
| --- | --- | --- | --- | --- |
| Agency discovery | `Gobusgo.OneBusAway.AgencyScheduler` | `AgencyRecorder.record/2` | 60 seconds | 45 seconds |

A run returns `{:ok, term}` or `{:error, term}` and logs its own outcome; the scheduler logs a run that crashes, a run it kills at the deadline, and the ticks it skipped during a run. The settings travel inside the run function, so a spec never shows the key when it is inspected. A new source is a new entry in `specs/2`, with a deadline shorter than its interval unless skipped ticks are intended.

## Published records

Every record goes through `Gobusgo.Publisher.publish/2`, which names no backend, and holds one CloudEvent 1.0 in structured mode built by `Gobusgo.CloudEvent`: compact JSON with sorted keys, a `content-type` header of `application/cloudevents+json`, and the `partitionkey` attribute as the record key. The `type` carries the version as its suffix.

| Record | Topic | Key | `type` | Built by |
| --- | --- | --- | --- | --- |
| Response stored | `oba.agencies-with-coverage.response-stored` | `oba/agencies-with-coverage` | `gobusgo.response.stored.v1` | `RawAgencyResponse.StoredEvent.record/1` |
| Agency | `oba.agencies-with-coverage.state` | `agency/<agency id>` | `gobusgo.agency.processed.v1` | `AgencyBatch.Records.build/1` |
| Manifest | `oba.agencies-with-coverage.state` | `manifest` | `gobusgo.agency.fetch.completed.v1` | `AgencyBatch.Records.build/1` |

Event attributes and `data`:

| Record | `id` | `source` | `time` | `subject` | `data` |
| --- | --- | --- | --- | --- | --- |
| Response stored | A UUID version 7 | The producer's | The producer's | The stored destination | `dataset`, `destination`, `fetchedAt`, `dataSha256`, `requestId` |
| Agency | `<requestId>/agency/<agency id>` | `/gobusgo/processor/oba/agencies-with-coverage` | The fetch time | The agency identifier | `agency` (`id`, `name`, `url`, `timezone`, `coverage` with `lat`, `lon`, `latSpan`, `lonSpan`), `fetchedAt`, `requestId` |
| Manifest | `<requestId>/manifest` | `/gobusgo/processor/oba/agencies-with-coverage` | The fetch time | The stored destination | `agencyIds` (sorted), `dataSha256`, `destination`, `fetchedAt`, `requestId` |

The agency and manifest records are a pure function of the stored response, so a repeated run publishes the same bytes. The `agency/` prefix keeps an agency identifier from ever equaling the manifest key. The manifest completes a fetch and is the source of membership: an agency absent from `agencyIds` is gone.

## Agency processor

`Gobusgo.OneBusAway.AgencyBatch.process/2` takes the destination of one stored response, the destination a "response stored" event names. It reads through `Gobusgo.Reader`, validates with `RawAgencyResponse.parse/1`, and publishes through `Gobusgo.Publisher`: the agency records in one call, then the manifest record once that call returns `:ok`. It runs in the calling process, lists nothing, keeps nothing between calls, and names no backend. Every valid response is published, changed or not.

A success is `{:ok, %{destination: ..., request_id: ..., fetched_at: ..., agency_count: ...}}`. A failure is `{:error, %{class: ..., error_code: ..., stage: ..., reason: ...}}`, and no manifest is published for it:

| `stage` | `error_code` | `class` |
| --- | --- | --- |
| `:read` | `READ_FAILURE` | `:permanent` for `:not_found`, `:content_too_large`, and `{:invalid_destination, reason}`; `:transient` for `:permission_denied` and `:io_failure` |
| `:parse` | `INVALID_JSON`, `SCHEMA_MISMATCH`, `HASH_MISMATCH`, or `DESTINATION_MISMATCH`, from the `RawAgencyResponse.parse/1` reason | `:permanent` |
| `:publish_agencies`, `:publish_manifest` | `WRITE_FAILURE` | `:permanent` for `:record_too_large`; `:transient` for `:timeout`, `:unavailable`, and `:unknown_topic` |

A `:permanent` failure repeats on every call. The error codes are the dead-letter `ERROR_CODE` values decided in GOB-48.

The processor logs `info` `Agency batch published` with `destination`, `request_id`, and `agency_count` when it publishes. A failure returns to the caller unlogged; the trigger logs the decision it takes.

## Agency trigger

`Gobusgo.OneBusAway.AgencyTrigger.handle/2` takes one consumed "response stored" record, with its topic, partition, offset, key, value, and headers, and returns once its outcome is final. `RawAgencyResponse.StoredEvent.decode/1` validates the value; an event that is not JSON, does not match the schema, or has another `type` is dead-lettered without an attempt (`INVALID_JSON`, `SCHEMA_MISMATCH`, `UNSUPPORTED_TYPE`). Otherwise each attempt runs `AgencyBatch.process/2` as a task with a 10-second deadline. `Gobusgo.OneBusAway.AgencyTrigger.Policy` is pure and decides what follows:

| Attempt outcome | While attempts remain | After the third attempt |
| --- | --- | --- |
| Published | Finished | Finished |
| `:transient` failure | Retry after a jittered delay of up to 500 ms, then 1,000 ms | Dead-letter with the failure's `error_code` and `EXHAUSTED_RETRY_CONDITION` |
| Deadline exceeded | Retry | Dead-letter as `TIMEOUT`, exhausted |
| Crashed | Retry | Dead-letter as `INTERNAL_ERROR`, exhausted |
| `:permanent` failure | Dead-letter at once with its `error_code` | — |

`Gobusgo.DeadLetter.record/1` builds the dead-letter record: the consumed key and value untouched, on the consumed topic's `.dead-letter` topic, with the consumed headers followed by `ERROR_CODE`, `ERROR_MESSAGE`, `RETRY_ATTEMPTS`, `EXHAUSTED_RETRY_CONDITION` (exhausted only), `ORIGINAL_TOPIC`, `ORIGINAL_PARTITION`, `ORIGINAL_OFFSET`, `CONSUMER_GROUP`, `FIRST_ATTEMPT_TIME`, and `LAST_ATTEMPT_TIME`. A dead-letter record that three publish tries do not store returns `{:error, {:dead_letter_unpublished, reason}}`.

The trigger logs at most one line per record: `warning` `Agency trigger processed after retries`, `error` `Agency trigger dead-lettered`, or `error` `Agency trigger dead letter not published`, with `error_code`, `attempt_count`, `retries_exhausted`, `topic`, `partition`, `offset`, and, for a parsed event, `event_id`, `destination`, and `request_id`.

`Gobusgo.OneBusAway.AgencyTrigger.KafkaConsumer` is the Broadway pipeline the application runs on `oba.agencies-with-coverage.response-stored` as the consumer group `gobusgo.agency-processor`, starting from the earliest record when the group has no offset. It acknowledges a record that is processed or dead-lettered. For a record whose dead-letter record is not published it kills its own processor, the only way to leave a Broadway Kafka message unacknowledged: the partition's committed offset stays before that record, and the record is delivered again when the group next assigns the partition.

## Agency view

`Gobusgo.OneBusAway.AgencyView` holds the agencies of the latest complete fetch in memory, and the REST API and the agency test page read it. A view is a process registered under a name and a table of the same name, started with the publish-subscribe server it announces on; the application starts one named `Gobusgo.OneBusAway.AgencyView` on `Gobusgo.PubSub`. `Gobusgo.OneBusAway.AgencyView.State` holds the rules and is pure.

- `apply_records/2` takes record values, the bytes `AgencyBatch.Records.build/1` produces, and applies them in order. `AgencyBatch.Records.decode/1` validates each one; a value it rejects is skipped and counted.
- A fetch is complete when its manifest and every agency the manifest names have been applied, in either order. The view switches to a complete fetch in one step, so a reader sees a whole fetch or the one before it.
- A record is ignored when its fetch is the current one or is older than the current one. A fetch with the same fetch time and another request identifier replaces the current one.
- At most 8 incomplete fetches are held, the oldest forgotten first, each with at most 1,000 agencies. A switch forgets every held fetch older than the new current one.
- Outside the test environment, `Gobusgo.Kafka.TopicSubscriber` calls `apply_records/2` with the values of `oba.agencies-with-coverage.state`, read from its earliest record on every start.
- When the current fetch changes, the view announces it once, after the table holds the new fetch, as `{:agency_view_switched, view}` to every process that called `subscribe/1`. A fetch that is held or ignored announces nothing.
- `current/1` reads the table without calling the process and returns `nil` before a fetch is complete and while the view is not running.
- The view starts empty and holds nothing across a restart.

Per `apply_records/2` call the view logs `info` `Agency view switched` with `request_id`, `fetched_at`, and `agency_count`; `warning` `Agency view skipped invalid records` with `invalid_count`; and `warning` `Agency view switch not announced` with `reason` when the announcement could not be sent.

In the test environment the configured publisher backend, `Gobusgo.Publisher.InProcess`, calls `apply_records/2` with the records published to `oba.agencies-with-coverage.state`. It calls `Gobusgo.OneBusAway.AgencyBatch.Consumer.consume/2` with the records published to `oba.agencies-with-coverage.response-stored`. The consumer decodes each value with `RawAgencyResponse.StoredEvent.decode/1` and calls `AgencyBatch.process/2` with the destination it names, in order, in the publishing process. A value that is not a "response stored" event is skipped and counted in one `warning` `Agency batch consumer skipped invalid events`; a stored response that fails to process is left failed, with no retry and no dead letter, and logged once at `error` `Agency batch consumer failed` with `destination`, `stage`, `error_code`, and `class`.

`AgencyRecorder.record/2` publishes one "response stored" event once the writer has stored the response, with the `source` `/gobusgo/recorder/oba/agencies-with-coverage`, a new UUID version 7 as `id`, and the fetch time as `time`. A failed publish leaves the result `{:ok, recorded}` and logs `warning` `OneBusAway agency response recorded without its event` with the `reason` in place of the `info` line.

## Vehicle records and vehicle view

No recorder or processor for `vehicles-for-agency` exists. The records and the view below are the contract those will publish to, and nothing publishes to it outside the tests. The requester above returns its vehicles in this contract's form.

The trip status element documents `position` as the real-time position when one is available and the scheduled position otherwise, `lastKnownLocation` as the last reported position, and `lastUpdateTime` and `lastLocationUpdateTime` as milliseconds since the Unix epoch with zero for "none received". Where each sits in the live response is in the table above.

`Gobusgo.OneBusAway.VehicleBatch.Records.build/1` takes the vehicles one request for one agency returned and builds the records; `decode/1` reads one back and returns a rule it breaks as a value. Both are pure.

| Record | Topic | Key | `type` |
| --- | --- | --- | --- |
| Vehicle | `oba.vehicles-for-agency.state` | `vehicle/<agency id>/<vehicle id>` | `gobusgo.vehicle.processed.v1` |
| Manifest | `oba.vehicles-for-agency.state` | `manifest/<agency id>` | `gobusgo.vehicle.fetch.completed.v1` |

| Record | `id` | `source` | `time` | `subject` | `data` |
| --- | --- | --- | --- | --- | --- |
| Vehicle | `<requestId>/vehicle/<agency id>/<vehicle id>` | `/gobusgo/processor/oba/vehicles-for-agency` | The fetch time | The vehicle identifier | `vehicle`, `fetchedAt`, `requestId` |
| Manifest | `<requestId>/manifest/<agency id>` | `/gobusgo/processor/oba/vehicles-for-agency` | The fetch time | The stored destination | `agencyId`, `vehicleIds` (sorted), `dataSha256`, `destination`, `fetchedAt`, `requestId` |

`data.vehicle` always holds every key below. `id` and `agencyId` are non-empty strings, and every other field is `null` when the source did not supply it, so a missing value is told apart from a supplied one.

| Field | Meaning |
| --- | --- |
| `id` | The vehicle identifier |
| `agencyId` | The agency the fetch asked for |
| `activeTripId` | The trip the vehicle serves |
| `position` | `lat` and `lon` of where the source places the vehicle now: an estimate, extrapolated or taken from the schedule when no fresh report exists |
| `orientation` | The direction that goes with `position`, in degrees |
| `lastKnownLocation` | `lat` and `lon` of the last location the vehicle reported |
| `lastKnownOrientation` | The last direction the vehicle reported, in degrees; also `0` for a vehicle that has reported no location |
| `lastUpdateTimeMs` | When the source last heard from the vehicle, milliseconds since the Unix epoch; `0` is the source's "never" |
| `lastLocationUpdateTimeMs` | When the vehicle last reported a location, milliseconds since the Unix epoch; `0` is the source's "never" and is kept apart from `null` |
| `predicted` | Whether the source has real-time data for the vehicle's trip; `true` also when the vehicle has reported no location |

The source's update times are kept apart from `fetchedAt`, which is when Gobusgo made the request.

`Gobusgo.OneBusAway.VehicleView` holds the vehicles of each agency's latest complete fetch in memory, and the vehicle test page at `/vehicles` reads it. It is a process registered under a name and a table of the same name, started with the publish-subscribe server it announces on; the application starts one named `Gobusgo.OneBusAway.VehicleView` on `Gobusgo.PubSub`, and `Gobusgo.Publisher.InProcess` calls its `apply_records/2` with the records published to `oba.vehicles-for-agency.state`. `Gobusgo.OneBusAway.VehicleView.State` holds the rules and is pure.

- A fetch belongs to one agency. It is complete when its manifest and every vehicle the manifest names have been applied, in either order. The view switches that agency to the fetch in one step and leaves every other agency's current fetch as it is.
- A record is ignored when its fetch is its agency's current one or is older than it, and when its fetch time or agency differs from the ones its fetch is held under. A fetch with the same fetch time and another request identifier replaces the agency's current one.
- At most 64 agencies have a current fetch, at most 32 incomplete fetches are held, the oldest forgotten first, and a fetch holds at most 5,000 vehicles. A switch forgets every held fetch of the same agency older than the new current one.
- An `apply_records/2` call that switches at least one agency announces once, after the table holds the new fetches, as `{:vehicle_view_switched, view}` to every process that called `subscribe/1`.
- `current/1` reads the table without calling the process and returns the current fetch of every agency, in agency identifier order, each with its own fetch time. It returns `[]` before a fetch is complete and while the view is not running.
- An agency that is no longer fetched keeps its last fetch. The view starts empty and holds nothing across a restart.

Per `apply_records/2` call the view logs `info` `Vehicle view switched` with `agency_count` and `vehicle_count`; `warning` `Vehicle view skipped invalid records` with `invalid_count`; and `warning` `Vehicle view switch not announced` with `reason`.

## Reconciliation

`Gobusgo.OneBusAway.Reconciliation.republish/2` takes `%{dataset: ..., range: %{start_at: ..., end_at: ...}}` and publishes a "response stored" event again for every stored response of the dataset fetched inside the half-open range `[start_at, end_at)`. The only dataset is `oba/agencies-with-coverage`. Both bounds are UTC times at whole seconds, and a range touches at most 32 UTC dates and holds at most 10,000 stored responses. `Gobusgo.OneBusAway.Reconciliation.TimeRange` holds the range rules and is pure.

It lists the `dt` partition of every date the range touches, takes the destinations whose name carries a fetch time inside the range, and reads them one at a time in destination order. A stored response `RawAgencyResponse.parse/1` rejects is skipped with its reason and gets no event; a destination whose name carries no fetch time is skipped as `destination_mismatch` without being read. Each event has the `source` `/gobusgo/reconciliation/oba/agencies-with-coverage`, a new UUID version 7 as `id`, and the fetch time as `time`. Events are published in destination order, at most 1,000 per publisher call, and the trigger processes each one like a recorder's event.

| Result | Meaning |
| --- | --- |
| `{:ok, %{published_count: ..., skipped: [...]}}` | The events are published; `skipped` lists each skipped destination with its reason |
| `{:error, :unknown_dataset}` | The dataset is not known; nothing is read |
| `{:error, :too_many_files}` | The range or its partitions exceed the bounds; nothing is published |
| `{:error, {:read, reason}}` | Discovering or reading failed; nothing is published |
| `{:error, {:publish, reason}}` | A publisher call failed; events of earlier calls are published |

Reconciliation logs one line per call: `info` `Reconciliation finished`, `warning` `Reconciliation finished with skips`, or `error` `Reconciliation failed`, with `dataset`, `range_start`, `range_end`, and the counts or the failure `reason`.

## Methods for future work

Not implemented here. Each link was checked 2026-10-01 from the method index.

- Stops: [`stop`](https://developer.onebusaway.org/api/where/methods/stop), [`stops-for-location`](https://developer.onebusaway.org/api/where/methods/stops-for-location), [`stops-for-agency`](https://developer.onebusaway.org/api/where/methods/stops-for-agency), [`stops-for-route`](https://developer.onebusaway.org/api/where/methods/stops-for-route), [`schedule-for-stop`](https://developer.onebusaway.org/api/where/methods/schedule-for-stop)
- Routes: [`route`](https://developer.onebusaway.org/api/where/methods/route), [`routes-for-agency`](https://developer.onebusaway.org/api/where/methods/routes-for-agency), [`routes-for-location`](https://developer.onebusaway.org/api/where/methods/routes-for-location)
- Arrivals: [`arrivals-and-departures-for-stop`](https://developer.onebusaway.org/api/where/methods/arrivals-and-departures-for-stop), [`arrival-and-departure-for-stop`](https://developer.onebusaway.org/api/where/methods/arrival-and-departure-for-stop)

List-returning methods must follow the bounded-read contract (explicit bound, lazy async iterator). Check each method's page for its paging and `limitExceeded` behavior before implementing.

## Open items

1. Rate limits and `Retry-After` behavior are undocumented in the pages checked.
