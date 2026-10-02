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

Every request carries the `key` query parameter. The key is read from configuration at runtime (environment variable `ONEBUSAWAY_API_KEY`, proposed name) and never committed, logged, or written to documentation. The documentation's `key=TEST` example value is not a credential for this project.

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
