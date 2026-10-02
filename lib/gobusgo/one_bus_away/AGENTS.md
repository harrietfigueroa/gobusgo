# OneBusAway integration (Puget Sound / Sound Transit)

OneBusAway (OBA) is an open-source transit API. Gobusgo reads the Puget Sound deployment, which serves Sound Transit and the other regional agencies, starting with agency discovery via `agencies-with-coverage`. Stop, route, and arrival methods are listed below for future work and are out of scope until implemented.

## Documentation sources

All links checked 2026-10-01.

- Method index: https://developer.onebusaway.org/api/where/methods
- REST conventions, envelope, response codes, references: https://developer.onebusaway.org/api/where
- `agencies-with-coverage`: https://developer.onebusaway.org/api/where/methods/agencies-with-coverage
- API key process: https://www.soundtransit.org/help-contacts/business-information/open-transit-data-otd

## Server and credentials

The documentation host (`developer.onebusaway.org`) serves docs only; it is not the API server. The Puget Sound API server is `https://api.pugetsound.onebusaway.org`, taken from the example request in the `agencies-with-coverage` documentation (checked 2026-10-01). Assumption, unverified by a live call: that this host is the production Sound Transit server and accepts keys issued through the process below. Verify with one authenticated request once a key exists.

Key process, per Sound Transit: email `oba_api_key@soundtransit.org` with the contact's first and last name, an email address if different from the sender, and acknowledgment of the Transit Data Terms of Use. Sound Transit states processing takes 20 business days. Status: unresolved until a key is issued.

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

`Gobusgo.OneBusAway.Agencies.fetch/2` is the agency discovery requester and `Gobusgo.OneBusAway.Client.get/3` is the only module that issues HTTP requests. The client sets `retry: :transient` with a capped, jittered `retry_delay` (a custom delay function replaces Req's `Retry-After` handling, which suits an API that documents none), `redirect: false`, `decode_body: false`, explicit timeouts, and a total deadline enforced around all attempts. The key is passed via `params:` and scrubbed from every returned value. Returned errors: `{:transport, reason}`, `:deadline_exceeded`, `{:http_status, status}`, `{:unexpected_redirect, status}`, `{:api_error, %{code: code, text: text}}`, `:invalid_json`. Schema violations, unreferenced agency ids, `limitExceeded: true`, and undocumented statuses raise `Gobusgo.Assert.AssertionError`.

`Gobusgo.OneBusAway.Agencies.fetch_response/2` makes the same request and returns the agencies together with the whole decoded envelope, the HTTP status, the method, the host, and the fetch time. The key is replaced wherever the server echoes it in the envelope, and the host is the host name alone, so no returned value carries a credential or a URL. Its `:clock` option supplies the fetch time.

`Gobusgo.OneBusAway.Agencies.parse/1` is the pure function from an envelope's `data` to the agencies. It returns a contract violation as a value: `{:schema_mismatch, mismatch}`, `{:agency_count_exceeded, count}`, or `{:unreferenced_agency, id}`. The requester raises on those values; a reader of stored responses handles them.

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

The processor logs one line per call: `info` `Agency batch published` with `destination`, `request_id`, and `agency_count`; or `error` `Agency batch failed` with `destination`, `stage`, `error_code`, `class`, and `reason`.

## Reconciliation

`Gobusgo.OneBusAway.Reconciliation.republish/2` takes `%{dataset: ..., range: %{start_at: ..., end_at: ...}}` and publishes a "response stored" event again for every stored response of the dataset fetched inside the half-open range `[start_at, end_at)`. The only dataset is `oba/agencies-with-coverage`. Both bounds are UTC times at whole seconds, and a range touches at most 32 UTC dates and holds at most 10,000 stored responses. `Gobusgo.OneBusAway.Reconciliation.TimeRange` holds the range rules and is pure.

It lists the `dt` partition of every date the range touches, takes the destinations whose name carries a fetch time inside the range, and reads them one at a time in destination order. A stored response `RawAgencyResponse.parse/1` rejects is skipped with its reason and gets no event; a destination whose name carries no fetch time is skipped as `destination_mismatch` without being read. Each event has the `source` `/gobusgo/reconciliation/oba/agencies-with-coverage`, a new UUID version 7 as `id`, and the fetch time as `time`. Events are published in destination order, at most 1,000 per publisher call.

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

1. API key not yet requested or issued (20 business days per Sound Transit).
2. Production status of `api.pugetsound.onebusaway.org` for Sound Transit confirmed only by the documentation example, not by a live call.
3. Rate limits and `Retry-After` behavior are undocumented in the pages checked.
