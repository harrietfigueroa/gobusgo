# OneBusAway integration (Puget Sound / Sound Transit)

OneBusAway (OBA) is an open-source transit API. Gobusgo reads the Puget Sound deployment, which serves Sound Transit and the other regional agencies, through agency discovery via `agencies-with-coverage` and the active vehicles of each agency via `vehicles-for-agency`. It also holds the two route datasets, the routes of each agency via `routes-for-agency` and the stops and paths of each route via `stops-for-route`, with their recorders, processors, and views; the route source fetches each once a day. The stops come out of the `stops-for-route` responses, into a record and a view of their own. The stop and arrival methods and the other route methods are listed below for future work and are out of scope until implemented.

## Documentation sources

All links checked 2026-10-01.

- Method index: https://developer.onebusaway.org/api/where/methods
- REST conventions, envelope, response codes, references: https://developer.onebusaway.org/api/where
- `agencies-with-coverage`: https://developer.onebusaway.org/api/where/methods/agencies-with-coverage
- API key process: https://www.soundtransit.org/help-contacts/business-information/open-transit-data-otd
- `vehicles-for-agency`: https://developer.onebusaway.org/api/where/methods/vehicles-for-agency — checked 2026-10-02
- Trip status element: https://developer.onebusaway.org/api/where/elements/trip-status — checked 2026-10-06
- `arrivals-and-departures-for-stop`: https://developer.onebusaway.org/api/where/methods/arrivals-and-departures-for-stop — checked 2026-10-06
- Arrival and departure element: https://developer.onebusaway.org/api/where/elements/arrival-and-departure — checked 2026-10-06

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

`Gobusgo.OneBusAway.Agencies.fetch/2` is the agency discovery requester and `Gobusgo.OneBusAway.Client.get/3` is the only module that issues HTTP requests. `Gobusgo.OneBusAway.Envelope.interpret/2` is the pure step every requester shares from an HTTP status and body to the decoded envelope or a documented failure. The client retries network faults and the statuses 408, 500, 502, 503, and 504 with a capped, jittered `retry_delay` (a custom delay function replaces Req's `Retry-After` handling, which suits an API that documents none), and sets `redirect: false`, `decode_body: false`, explicit timeouts, and a total deadline enforced around all attempts and every wait at the request gate. It sets `inet6: true`, fixed in code (decided in GOB-170): Mint tries IPv6 first and connects over IPv4 when that attempt fails, so one setting serves a network with no IPv4 route and a machine with no IPv6. Each of the two attempts has the 5-second connect timeout of its own, so on a network that drops IPv6 packets without an answer a connection takes 5 seconds longer. The key is passed via `params:` and scrubbed from every returned value. The client's `:params` option carries a method's other query parameters, and a parameter named `key` among them raises. Returned errors: `{:transport, reason}`, `:deadline_exceeded`, `:rate_limited`, `{:http_status, status}`, `{:unexpected_redirect, status}`, `{:api_error, %{code: code, text: text}}`, `:invalid_json`. Schema violations, unreferenced agency ids, `limitExceeded: true`, and undocumented statuses raise `Gobusgo.Assert.AssertionError`.

`Gobusgo.OneBusAway.Agencies.fetch_response/2` makes the same request and returns the agencies together with the whole decoded envelope, the HTTP status, the method, the host, and the fetch time. The key is replaced wherever the server echoes it in the envelope, and the host is the host name alone, so no returned value carries a credential or a URL. Its `:clock` option supplies the fetch time.

`Gobusgo.OneBusAway.Agencies.parse/1` is the pure function from an envelope's `data` to the agencies. It returns a contract violation as a value: `{:schema_mismatch, mismatch}`, `{:agency_count_exceeded, count}`, or `{:unreferenced_agency, id}`. The requester raises on those values; a reader of stored responses handles them.

## Agency coverage

`Gobusgo.OneBusAway.AgencyCoverage` is the pure geometry of the coverage entries. `bounds/1` turns one entry into `south`, `west`, `north`, and `east`: the center minus and plus half of each span. `extract_regions/2` takes agencies as `Agencies.parse/1` returns them and a buffer in meters, and returns each agency's own bounds for the initial map view, the regions for the basemap extracts, and the agencies it skipped with the reason. Nothing calls it yet.

Shape of the live coverage, observed in the response stored on 2026-10-03 (12 agencies): every entry is a center and two spans, and the response carries no polygon or other geometry. The spans are the whole height and width of the box: King County Metro (`1`) comes out as 47.19 to 47.87 north and -122.51 to -121.79 east. Solid Ground EZ Loop (`6289`) has `lat`, `lon`, `latSpan`, and `lonSpan` all `0.0`, which is how the server reports an agency with no coverage. The other eleven boxes overlap into one region, 46.93 to 48.60 north and -123.01 to -121.60 east before the buffer.

| Rule | Value | Meaning |
| --- | --- | --- |
| Missing coverage | All four numbers zero | `{:error, :coverage_missing}`; the agency is skipped |
| Invalid coverage | A negative span, an edge beyond a pole, or an edge beyond the antimeridian | `{:error, {:coverage_invalid, field}}`; the agency is skipped |
| Buffer | The caller's, at most 100,000 meters | Added on every side; a degree of latitude counts as 111,320 meters, and the east and west sides use the degrees of longitude that cover the buffer at the box's edge farthest from the equator |
| Combining | Buffered boxes that overlap or touch | Replaced by the box that holds both, repeated until no two regions share an area |
| Agency bound | 1,000 | The most agencies one call takes |

A region is a box, so the box that holds two overlapping areas also holds ground neither covers. A coverage box across the antimeridian is invalid, because the bounds keep `west <= east`.

## Request gate

`Gobusgo.OneBusAway.RequestGate` owns the request budget of the API key. The application starts one, registered under the module's name, and `Client.get/3` takes a permit from it before every attempt, a retry included, and releases the permit with the attempt's outcome; its `:gate` option names another gate, which the tests use. `Gobusgo.OneBusAway.RequestGate.State` holds the rules and is pure. The gate never sees the key.

| Rule | Value | Meaning |
| --- | --- | --- |
| Refill interval | 200 ms | Five permits a second; the bucket holds one token, so idle time buys no burst |
| In-flight cap | 4 | Permits held at one time |
| Waiter bound | 32 | Callers waiting for a permit, served in arrival order |
| Backoff window | 1,000 ms doubling to 60,000 ms | The pause after a 429 without `Retry-After`, jittered between half the window and all of it |
| `Retry-After` bound | 300,000 ms | The longest pause a response can name |

- A caller waits for a permit until 250 ms before its request's deadline. A caller whose wait runs out, or who arrives while 32 callers wait, gets `{:error, :rate_limited}`, which the requesters return unchanged.
- A 429 response pauses every caller, is returned as `{:error, {:http_status, 429}}`, and is never retried by the client. When the pause ends, one caller probes alone: a response that is not a 429 reopens the gate and resets the window, another 429 pauses again for a doubled window, and a probe that ends with no response lets the next caller probe.
- The gate monitors each caller, so a caller that exits or is killed at its deadline gives up its permit or its place among the waiters.
- State is in memory and per node: a restart begins open with a full bucket, and two running instances each spend a full budget.
- Logs: `warning` `OneBusAway request gate paused` with `pause_ms` and `pause_count`, and `info` `OneBusAway request gate reopened`.

The budget of five requests per second is an assumption, half of the ten the gate first granted (decided in GOB-158). OneBusAway documents neither a rate limit nor a 429 status nor `Retry-After` (https://developer.onebusaway.org/api/where — checked 2026-10-03); the gate treats a 429 as rate limiting on the project owner's statement that limits exist. The live server has answered with 429: on 2026-10-03, with agency discovery once a minute and twelve vehicle fetches every five seconds, two requests in 75 seconds got one. The pause each one caused and whether the response carried `Retry-After` were not recorded. On 2026-10-06 a test that sent one `arrivals-and-departures-for-stop` request every 1.5 seconds beside a running application's twelve vehicle fetches every five seconds, about three requests a second together, got a 429 on its 223rd request, eleven minutes in. So the server has refused below five requests a second, the limit itself is still unknown, and the gate's pause after a 429 is what holds the application under it.

A new source needs no change here: its requests reach the gate through the client. A deadline shorter than the time its requests spend waiting for permits ends in `:rate_limited`, so a source that issues many requests per run sizes its deadline to 200 ms per request, plus the time the requests themselves take while four are in flight.

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

The mapping to the published vehicle follows from that table: `lastKnownLocation` comes from the vehicle's `location`, so a vehicle without a trip keeps its last report; `position`, `orientation`, `lastKnownOrientation`, `activeTripId`, `predicted`, `scheduleDeviation`, `nextStop`, and `nextStopTimeOffset` come from `tripStatus` and are `null` without one; the two times come from the vehicle, and the trip status repeats them with the same values. `predicted` was `true` for every trip status, including trips whose vehicle had reported no location, and `lastKnownOrientation` was `0` for every vehicle without a reported location. A vehicle with only schedule data carries a block-derived identifier such as `40_H:121:0:Weekday:1:26SEP:52043:12345`; identifiers are opaque and never parsed. The response's `references` and `outOfRange` are kept in the envelope and not read.

Orientation values, observed on 2026-10-05 in the newest stored response of each of the 12 agencies (1,635 vehicles, 817 with a trip status). The documentation gives `orientation` as degrees with 0 east, 90 north, 180 west, and 270 south (trip status element, checked 2026-10-04).

- `orientation` was a number at least 0 and below 360 in every trip status, so a vehicle with a `position` always had one. 661 values had a fraction and 156 were whole.
- An `orientation` of `0` is a heading of east, not a missing value: the whole values were `0` (36), `90` (47), `180` (25), and `270` (51), the four directions of a street grid at similar counts. Of the 16 vehicles at `0` that moved more than 40 meters in a minute, 10 moved within 30 degrees of east.
- The convention holds in the feed: of 524 moving vehicles with another `orientation`, 417 moved within 45 degrees of it over a minute.
- `lastKnownOrientation` was `0` for 575 of the 632 vehicles that had reported a location, and for all 185 that had not, so it does not tell a heading for most vehicles.

Route data in the response's `references`, observed on 2026-10-05 in 1,570 stored responses of all 12 agencies. `Vehicles.parse/1` requires this shape and returns a schema mismatch for anything else.

- `references` was always an object whose `trips` and `routes` were lists, both empty for an agency with no vehicle on a trip.
- The trip of every `activeTripId` was in `trips`, and the route of every such trip was in `routes` (105,680 of 105,680 vehicles with a trip status).
- A trip's `id`, `routeId`, and `tripHeadsign` and a route's `id`, `shortName`, and `longName` were always strings. `shortName` was empty for 4,132 of 46,696 routes, all of them Washington State Ferries routes (agency `95`), which carry a `longName` such as `Seattle - Bainbridge Island`. `longName` was empty for about half of the routes.
- A route also carries `agencyId`, `color`, `textColor`, `description`, `type`, and `url`, and a trip a `shapeId`; none of these is read. The points of a shape come from another method that the application does not call.

The published vehicle takes `routeId` and `tripHeadsign` from the trip of its `activeTripId` and `routeShortName` and `routeLongName` from that trip's route. Each is `null` for a vehicle without a trip status, for a trip or a route the references lack, and for a name that is empty.

Test fixtures under `test/fixtures/one_bus_away/vehicles_for_agency*.json` are cut from the live Sound Transit response, one vehicle for each combination of trip and reported location.

## Routes: `routes-for-agency`

`GET /api/where/routes-for-agency/<agency id>.json?key=<key>` (https://developer.onebusaway.org/api/where/methods/routes-for-agency — checked 2026-10-05). The agency identifier is the only documented parameter besides `key`, and the requester percent-encodes it into the path. The method documents no paging, so the requester asserts `data.limitExceeded` is `false`.

`Gobusgo.OneBusAway.Routes.fetch_response/2` takes the agency in its `:agency_id` option and returns the routes together with the whole decoded envelope, the agency, the HTTP status, the method, the host, and the fetch time, with the same key hygiene and errors as the agency requester. Its dataset's recorder calls it, and the route cycle schedules it. `Gobusgo.OneBusAway.Routes.parse/2` is the pure function from `data` and the agency asked for to the routes. It returns a contract violation as a value: `{:schema_mismatch, mismatch}`, `{:route_count_exceeded, count}` above 1,000, `{:invalid_route, index}` for an empty identifier, a route of another agency, or a color that is not six hexadecimal digits, or `{:duplicate_route, id}`. The requester raises on those values.

A route holds `id`, `agency_id`, `short_name`, `long_name`, `description`, `type`, `color`, `text_color`, and `url`. `id`, `agency_id`, and `type` are always present, and every other field is `nil` when the source sends an empty string. `nullSafeShortName` is not read: it repeats `shortName`, or the route's `id` when `shortName` is empty.

Shape of the live response, observed on 2026-10-05 across all 12 agencies (391 routes, the largest list King County Metro's 134, none for Solid Ground EZ Loop, `limitExceeded` `false` throughout):

- Every route carried every field, `type` as an integer and the others as strings, with an empty string where the agency supplies nothing. The route element's documentation requires only `id`, `type`, and `agencyId` (https://developer.onebusaway.org/api/where/elements/route — checked 2026-10-05).
- Every route's `agencyId` was the agency asked for, and no identifier repeated.
- `color` and `textColor` were six hexadecimal digits or empty. 59 routes had an empty `color`: all 38 of Washington State Ferries (`95`), 20 of King County Metro (`1`), and the one of agency `96`. GTFS, which the fields come from, reads an empty color as white and an empty text color as black (https://gtfs.org/documentation/schedule/reference/ — checked 2026-10-05).
- `shortName` was empty for 39 routes and `longName` for 134, never both. `description` was empty for 243 and `url` for 77; every other `url` was an `http` or `https` address.
- `type` was `3` (bus) for 334 routes, `4` (ferry) for 48, `0` (light rail) for 5, and `2` (rail) for 4.
- `references` held the agency asked for and nothing else. The requester does not read it.

Test fixtures under `test/fixtures/one_bus_away/routes_for_agency*.json` are cut from the live Sound Transit response: a rail route, a bus route with no long name, and a light rail route.

## Route paths: `stops-for-route`

`GET /api/where/stops-for-route/<route id>.json?includePolylines=true&key=<key>` (https://developer.onebusaway.org/api/where/methods/stops-for-route — checked 2026-10-05). `includePolylines` defaults to `true` and the requester sends it all the same. The documented `time` parameter, which chooses the service date and defaults to today, is not sent. The route identifier is percent-encoded into the path.

`Gobusgo.OneBusAway.RoutePaths.fetch_response/2` takes the route in its `:route_id` option and returns the route path together with the whole decoded envelope, the route, the HTTP status, the method, the host, and the fetch time, with the same key hygiene and errors as the agency requester. A route the server does not know is `{:http_status, 404}`. Its dataset's recorder calls it, and the route cycle schedules it. `Gobusgo.OneBusAway.RoutePaths.parse/2` is the pure function from `data` and the route asked for to the route path. It returns a contract violation as a value: `{:schema_mismatch, mismatch}`, `{:route_mismatch, route_id}` for a response about another route, `{:stop_count_exceeded, count}` above 1,000 stops, `{:stop_grouping_count_exceeded, count}` above 8, `{:stop_group_count_exceeded, count}` above 16, `{:polyline_count_exceeded, count}` above 1,000 for the route's and the groups' polylines together, `{:invalid_polyline, polyline}`, `{:duplicate_stop, id}`, `{:unlisted_stop, id}` for a group's stop the route does not list, or `{:unreferenced_stop, id}`. The requester raises on those values.

A route path holds:

| Field | Meaning |
| --- | --- |
| `route_id` | The route |
| `stop_ids` | Every stop of the route, once |
| `polylines` | The whole route, with a stretch that several groups share held once |
| `stop_groupings` | Each with `type`, `ordered`, and `stop_groups` |
| `stop_groups` | Each with `id`, `name`, `names`, `name_type`, its `stop_ids` in order, and its own `polylines` |
| `stops` | The referenced stop of every identifier in `stop_ids`: `id`, `name`, `lat`, `lon`, `code`, `direction`, `location_type`, `parent`, `wheelchair_boarding`, `route_ids` |
| `parent_stops` | The referenced stop, outside `stop_ids`, of every identifier a stop names as `parent`, once and in identifier order, with the fields of a stop |

A polyline is `points`, `point_count`, and `levels`. `points` is in the encoded polyline format (https://developers.google.com/maps/documentation/utilities/polylinealgorithm — checked 2026-10-05) at five decimal places, and `point_count` is the source's `length`. The requester checks that `points` holds only the characters of that format and does not decode it. A field the source sends empty is `nil`.

Shape of the live response, observed on 2026-10-05 for all 391 routes of the 12 agencies; `parse/2` accepts every one of them:

- `data.entry` always held `routeId`, `stopIds`, `stopGroupings`, and `polylines`, and `routeId` was the route asked for.
- Every route had one grouping, of `type` `direction` and `ordered` `true`. It held two groups for 335 routes, one for 51, and none for 5. A group's `id` was `0` or `1`, its name's `type` was `destination`, and its `subGroups` was always empty; the requester does not read `subGroups`.
- A group's `names` held one name, equal to its `name`. One group, on route `1_7994`, had an empty `name` and `null` as its one name, which the requester returns as no names.
- `entry.polylines` is disconnected pieces, 36 per route on average and 278 at most, many of them 2 to 6 points long. A group's `polylines` are its own path, in 1 piece for 304 groups and in 127 at most. One of a route's two groups has its pieces in `entry.polylines` as well and the other does not. The largest route held 522 polylines in all.
- `length` was an integer, `levels` was always empty, and `points` held only characters of the encoding. `length` equaled the decoded point count in every polyline of the four routes decoded by hand; the requester does not check that.
- Six routes had no polylines, all of Kitsap Transit (`20`), and five of them had no stops and no groups either.
- No stop repeated in a route's `stopIds`, every stop of a group was in the route's `stopIds`, and every stop of a route had a reference. One stop of one route was in no group.
- A referenced stop always carried `id`, `name`, `lat`, `lon`, `code`, `direction`, `locationType`, `parent`, `wheelchairBoarding`, `routeIds`, and `staticRouteIds`. `name` and `code` were never empty, `direction` was empty for 1,385 of 19,074, `locationType` was always `0`, and `wheelchairBoarding` was `ACCESSIBLE`, `NOT_ACCESSIBLE`, or `UNKNOWN`. `staticRouteIds` is not read.
- 535 referenced stops were in no route's `stopIds`: the parent stations that other stops name in `parent`. Each response referenced exactly the stops its route lists and the parents those stops name, 27 parents at most for one route, and no parent named a parent. The requester returns them as `parent_stops`; a `parent` the response does not reference names a stop the route path does not hold.
- The routes listed 18,539 stops, 12,913 of them distinct, and 182 at most for one route.
- The responses were 794 to 77,685 bytes and 10.9 MB together, 1.9 MB compressed with gzip. The route polylines of all 391 routes hold 508,629 points in 1.4 MB of encoded text.
- At one request every 1.5 seconds, beside the application's own vehicle cycle on the same key, 3 of the 391 requests got a 429 and succeeded on the next try.

Not observed: nested `subGroups`, a non-empty `levels`, a grouping of another `type`, and a response with `includePolylines=false`, which on the one route tried kept every key and returned empty polyline lists.

Test fixtures under `test/fixtures/one_bus_away/stops_for_route*.json` are cut from the live response for the West Seattle Water Taxi (`1_100336`), whole.

## Arrivals: `arrivals-and-departures-for-stop`

`GET /api/where/arrivals-and-departures-for-stop/<stop id>.json?key=<key>`. The stop identifier is percent-encoded into the path. The method documents `minutesBefore`, default 5, and `minutesAfter`, default 35; the requester sends neither, so a response covers the default window. The method is unpaginated and its `data` holds one `entry` and no `limitExceeded`.

`Gobusgo.OneBusAway.Arrivals.fetch_response/2` takes the stop in its `:stop_id` option and returns the arrivals together with the whole decoded envelope, the stop, the HTTP status, the method, the host, and the fetch time, with the same key hygiene and errors as the agency requester. A stop the server does not know is `{:http_status, 404}`, with the envelope `{"code": 404, "text": "resource not found"}` (observed 2026-10-06). `Gobusgo.OneBusAway.ArrivalRecorder` calls it, the arrival cycle schedules the recorder, and GOB-158 holds the design of the flow. `Gobusgo.OneBusAway.Arrivals.parse/2` is the pure function from `data` and the stop asked for to the arrivals. It returns a contract violation as a value: `{:schema_mismatch, mismatch}`, `{:stop_mismatch, stop_id}` for a response about another stop, `{:arrival_count_exceeded, count}` above 500, or `{:invalid_arrival, index}` for an arrival at another stop, with an empty trip or route identifier, with a service date or a scheduled time of zero or less, or with a stop sequence before zero. The requester raises on those values.

An arrival holds the trip, the service date, the stop sequence, the route with its short and long names, the headsign, whether riders can arrive and depart on it, the scheduled and predicted arrival and departure times in milliseconds since the Unix epoch, `predicted`, the vehicle, and the vehicle's schedule deviation. A name the source sends empty is `nil`.

- **A predicted time is `nil` unless it can be shown.** The documentation gives a predicted time as "zero if no real-time available" and `predicted` as "true if we have real-time arrival info available for this trip". The requester reads a time as none when `predicted` is `false`, when the time is `0`, and when it is more than two hours from its scheduled time. The arrival time and the departure time are judged apart, and `predicted` is passed on as sent.
- **The vehicle's schedule deviation is `nil` unless the vehicle serves the arrival's trip.** Each arrival carries the `tripStatus` of its vehicle, which describes the vehicle's active trip: an earlier trip of the block until the vehicle starts this one. The deviation is read only when `tripStatus.activeTripId` is the arrival's `tripId`.
- **Nothing identifies an arrival within a response.** The source lists a trip twice when it matches two vehicles to it, with the same trip, service date, and stop sequence.

Shape of the live response, observed on 2026-10-06 about 19:15 Pacific in 224 responses for 99 stops of nine agencies (489 arrivals; GOB-158's comments hold the whole test):

| Observation | Count |
| --- | --- |
| Every key the schema names present with its type, each name a string | 489 of 489 |
| `tripStatus` present, a map with `activeTripId` and an integer `scheduleDeviation`; an absent key otherwise | 485 of 489 |
| `predicted` `false`, always with both predicted times `0` and an empty `vehicleId` | 56 |
| `predicted` `true` with a predicted time more than two hours from the schedule: agency `95` about 19.4 hours early, agency `19` near the epoch | 29 arrival times, 97 departure times |
| `routeLongName` empty; `routeShortName` and `tripHeadsign` never were | 91 |
| `arrivalEnabled` `false`, a trip's first stop | 61 |
| `departureEnabled` `false`, a trip's last stop | 63 |
| A trip listed twice in one response, the vehicle and its distance differing | 23 pairs in 18 responses |
| `frequency` and the four `Interval` fields `null` | 489 of 489 |

- A response held 2 arrivals at the middle and 25 at most; it was 5.7 KB at the middle and 77 KB at most, most of it the `tripStatus` of each arrival, and took 0.14 s at the middle.
- For an upcoming arrival whose vehicle serves its trip, the predicted time was the scheduled time plus `tripStatus.scheduleDeviation` to the second for agencies `1`, `19`, `40`, `95`, and `97` (141 of 148). Agencies `3`, `20`, and `29` have predictions per stop, a middle difference of 77, 10, and 6 seconds.
- A scheduled time was never `0`, and an arrival's `stopId` was always the stop asked for.
- The response's `references`, `nearbyStopIds`, and `situationIds` are kept in the envelope and not read.

Test fixtures under `test/fixtures/one_bus_away/arrivals_and_departures_for_stop*.json` are cut from the live response for the Seattle ferry terminal (`95_7`), whole: four arrivals, of which one has a usable predicted arrival, two have a predicted time about 19.7 hours early, and two have `predicted` `false`.

## Stored raw responses

`Gobusgo.OneBusAway.AgencyRecorder.record/2` calls `fetch_response/2` and passes the result through `Gobusgo.Writer.write/2`. It names no backend; application configuration selects one. `Gobusgo.OneBusAway.RawAgencyResponse.build/1` is the pure function that turns a response and a request identifier into the logical destination and the content.

What is stored: only an HTTP 200 response whose envelope `code` is 200 and whose `data` passes the requester's schema. Every other outcome returns `{:error, {:fetch, reason}}` or raises, and stores nothing. A writer failure returns `{:error, {:write, reason}}`. Writes are create-only, so every response is kept and none is replaced.

Logical destination:

```
raw/oba/agencies-with-coverage/dt=YYYY-MM-DD/<fetchedAt>_<requestId>_<dataHash12>.json.gz
```

The `.gz` ending makes the writer store the content as one gzip stream, and the reader returns the content as the recorder passed it. `meta.dataSha256` and every size and credential check apply to the content before compression. A response stored before compression has the same name ending in `.json` and holds the content as it is; `RawAgencyResponse.parse/1`, the processor, and reconciliation accept both names.

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

`Gobusgo.OneBusAway.RawResponse` holds what the stored form of every dataset shares: the wrapper, the `meta` fields above, the hash, the name, and the checks of `parse/1`. A dataset's module supplies its prefix, the segments between the date and the name, and its own `meta` fields. `RawVehicleResponse.build/1` stores one `vehicles-for-agency` response the same way, with `agencyId` in `meta`, at:

```
raw/oba/vehicles-for-agency/dt=YYYY-MM-DD/agency=<agency>/<fetchedAt>_<requestId>_<dataHash12>.json.gz
```

`agency` is the agency identifier with every byte outside `A-Z`, `a-z`, `0-9`, `_`, and `-` written as `.` and two uppercase hexadecimal digits. `RawVehicleResponse.parse/1` returns the fetch in the form `VehicleBatch.Records.build/1` takes, and rejects, beside the shared rules, a `meta` without an agency and data `Vehicles.parse/1` rejects.

The agency recorder logs one line per call: `info` `OneBusAway agency response recorded` with `destination`, `request_id`, `data_sha256`, and `content_bytes`; or `error` `OneBusAway agency response not recorded` with `stage` (`fetch` or `write`), `reason`, and `request_id`.

## Scheduled sources

`Gobusgo.OneBusAway.Sources.specs/2` returns one spec per source for `Gobusgo.Scheduler`: the name the scheduler is registered under, the function to run, the interval, and the deadline of one run. It is pure and starts nothing. The application starts a scheduler per spec when the OneBusAway settings are present, and none under test.

| Source | Scheduler name | Run | Interval | Deadline |
| --- | --- | --- | --- | --- |
| Agency discovery | `Gobusgo.OneBusAway.AgencyScheduler` | `AgencyRecorder.record/2` | 60 seconds | 45 seconds |
| Vehicles | `Gobusgo.OneBusAway.VehicleScheduler` | `VehicleCycle.run/2` | 5 seconds | 4.5 seconds |
| Routes | `Gobusgo.OneBusAway.RouteScheduler` | `RouteCycle.run/2` | 60 seconds | 55 seconds |
| Arrivals | `Gobusgo.OneBusAway.ArrivalScheduler` | `ArrivalCycle.run/2` | 5 seconds | 4.5 seconds |

A run returns `{:ok, term}` or `{:error, term}` and logs its own outcome; the scheduler logs a run that crashes, a run it kills at the deadline, and the intervals that elapsed during a run. The settings travel inside the run function, so a spec never shows the key when it is inspected. A new source is a new entry in `specs/2`, with a deadline shorter than its interval unless skipped intervals are intended.

`Gobusgo.OneBusAway.VehicleCycle.run/2` is one run of the vehicle source. It takes the agencies of the agency view's current fetch, at most 64, and calls `Gobusgo.OneBusAway.VehicleRecorder.record/2` for each in identifier order, one after another, each in a task under the ingestion task supervisor.

- An agency gets at most 2 seconds, and its fetch is not retried: the next cycle is its retry. An agency whose fetch fails, raises, or runs past its deadline is one failed agency, and the cycle goes on to the next.
- The cycle starts no agency once its budget of 4 seconds is spent; the agencies left are skipped and the next cycle fetches them. The budget ends before the run's deadline, so the scheduler does not kill a cycle that keeps to it.
- `VehicleRecorder.record/2` fetches with `Vehicles.fetch_response/2`, stores with `RawVehicleResponse.build/1`, and publishes one "response stored" event with the `source` `/gobusgo/recorder/oba/vehicles-for-agency`. It returns `{:ok, recorded}` with `event_published`, `{:error, {:fetch, reason}}`, or `{:error, {:write, reason}}`, raises on a response that breaks the schema, and logs nothing.
- The cycle returns `{:ok, counts}` with `agency_count`, `recorded_count`, `failed_count`, `skipped_count`, and `unannounced_count`, or `{:error, :nothing_recorded}` when there are agencies and none is recorded, which makes the scheduler back off. Before the agency view has a fetch there is no agency, which is `{:ok, counts}` with zeros.
- It logs one line per run with those counts and `failures`, the failed agencies counted by cause: `info` `OneBusAway vehicle cycle finished`, `warning` `OneBusAway vehicle cycle finished degraded` when an agency failed, was skipped, or was stored without its event, and `error` `OneBusAway vehicle cycle failed` when none is recorded.

Whether twelve fetches fit the 4-second budget against the live server is not measured; a cycle that does not fit logs the `warning` with its `skipped_count`.

`Gobusgo.OneBusAway.RouteCycle.run/2` is one run of the route source. The cadence, each item once every 24 hours at one request a second, is decided in GOB-92, and the way it runs in GOB-94.

- An item is the routes of one agency or the stops and paths of one route. The agencies are those of the agency view's current fetch, at most 64, and the routes are those the route view holds for them, at most 5,000.
- `Gobusgo.OneBusAway.RouteSchedule` is pure and says what is due. An identifier's slot is a minute of the UTC day, `:erlang.phash2(id, 1440)`, which is the same on every machine and release. An item is due when it has no fetch in its view, or when its fetch there was made before the latest time its slot came.
- The run every minute is what the scheduler's rules ask for: a scheduler starts a run when it starts and then once per interval, and backs off after a failed run for 1, 3, 7, then 15 intervals past the time the next run was due. A restart with fresh views fetches nothing, and the run after a failed one starts within sixteen minutes of it.
- A cycle records due agencies before due routes, each in identifier order, at most 45 items, and counts the rest as `deferred_count`. It starts one request a second and none with less than 250 ms of its 50-second budget left; the items the budget does not reach are `skipped_count`.
- An item gets at most 10 seconds and is not retried: it is still due in the next cycle. An item whose fetch fails, raises, or runs past its deadline is one failed item, and the cycle goes on to the next.
- The cycle returns `{:ok, counts}` with `due_count`, `recorded_count`, `failed_count`, `skipped_count`, `deferred_count`, and `unannounced_count`, or `{:error, :nothing_recorded}` when an item failed and none is recorded, which makes the scheduler back off.
- It logs one line per run with those counts and `failures`: `debug` `OneBusAway route cycle found nothing due`, `info` `OneBusAway route cycle finished`, `warning` `OneBusAway route cycle finished degraded`, and `error` `OneBusAway route cycle failed`.

With the 12 agencies and 391 routes of 2026-10-05, a first start records the 12 route lists in its first cycle and the 391 paths over the nine cycles after it, and from then on about one item every three and a half minutes. On the first day each item is fetched twice, at the fill and when its slot first comes. This is not measured against the live server.

`Gobusgo.OneBusAway.RouteBackfill.run/2` fetches the same items once, due or not: the routes of every agency, then the stops and paths of every route those agencies list, read back from the responses it stored. `mix gobusgo.routes.backfill` calls it with a request gate and a Kafka client of its own, and does not start the application, so the task and a running application each pace their own requests against the one key.

- One request starts every second, the request for the agencies and every repeated request included.
- A request answered with 429, or one the request gate gives no permit, is tried again, three times in all. The server's documentation names no 429 (https://developer.onebusaway.org/api/where — checked 2026-10-05); the live server sends it.
- A response that breaks the contract is one failed item with the cause `contract_violation`; the backfill goes on.
- After ten failed items in a row the backfill stops and counts the items left as skipped.
- `report/1` turns the summary into the lines the task prints.

Run against the live server on 2026-10-05 for agency `23` with `--route-limit 2`: three responses recorded one second apart, three files stored, and three events on `oba.routes.response-stored`. The whole feed has not been backfilled with it.

## Published records

Every record goes through `Gobusgo.Publisher.publish/2`, which names no backend, and holds one CloudEvent 1.0 in structured mode built by `Gobusgo.CloudEvent`: compact JSON with sorted keys, a `content-type` header of `application/cloudevents+json`, and the `partitionkey` attribute as the record key. The `type` carries the version as its suffix.

| Record | Topic | Key | `type` | Built by |
| --- | --- | --- | --- | --- |
| Response stored | `oba.agencies-with-coverage.response-stored` | `oba/agencies-with-coverage` | `gobusgo.response.stored.v1` | `RawAgencyResponse.StoredEvent.record/1` |
| Response stored | `oba.vehicles-for-agency.response-stored` | `oba/vehicles-for-agency/<agency id>` | `gobusgo.response.stored.v1` | `RawVehicleResponse.StoredEvent.record/1` |
| Agency | `oba.agencies-with-coverage.state` | `agency/<agency id>` | `gobusgo.agency.processed.v1` | `AgencyBatch.Records.build/1` |
| Manifest | `oba.agencies-with-coverage.state` | `manifest` | `gobusgo.agency.fetch.completed.v1` | `AgencyBatch.Records.build/1` |

Event attributes and `data`:

| Record | `id` | `source` | `time` | `subject` | `data` |
| --- | --- | --- | --- | --- | --- |
| Response stored | A UUID version 7 | The producer's | The producer's | The stored destination | `dataset`, `destination`, `fetchedAt`, `dataSha256`, `requestId`, and for vehicles `agencyId` |
| Agency | `<requestId>/agency/<agency id>` | `/gobusgo/processor/oba/agencies-with-coverage` | The fetch time | The agency identifier | `agency` (`id`, `name`, `url`, `timezone`, `coverage` with `lat`, `lon`, `latSpan`, `lonSpan`), `fetchedAt`, `requestId` |
| Manifest | `<requestId>/manifest` | `/gobusgo/processor/oba/agencies-with-coverage` | The fetch time | The stored destination | `agencyIds` (sorted), `dataSha256`, `destination`, `fetchedAt`, `requestId` |

`Gobusgo.OneBusAway.StoredEvent` holds the "response stored" event the datasets share, and each dataset's module supplies its topic, dataset name, key, and own `data` fields. The agency events share one key, so they keep their order; a vehicle event's key names its agency, so one agency's events keep their order and the agencies spread over the partitions.

The agency and manifest records are a pure function of the stored response, so a repeated run publishes the same bytes. The `agency/` prefix keeps an agency identifier from ever equaling the manifest key. The manifest completes a fetch and is the source of membership: an agency absent from `agencyIds` is gone.

## Agency processor

`Gobusgo.OneBusAway.AgencyBatch.process/2` takes the destination of one stored response, the destination a "response stored" event names. It reads through `Gobusgo.Reader`, validates with `RawAgencyResponse.parse/1`, and publishes through `Gobusgo.Publisher`: the agency records in one call, then the manifest record once that call returns `:ok`. It runs in the calling process, lists nothing, keeps nothing between calls, and names no backend. Every valid response is published, changed or not.

A success is `{:ok, %{destination: ..., request_id: ..., fetched_at: ..., agency_count: ...}}`. A failure is `{:error, %{class: ..., error_code: ..., stage: ..., reason: ...}}`, and no manifest is published for it:

| `stage` | `error_code` | `class` |
| --- | --- | --- |
| `:read` | `READ_FAILURE` | `:permanent` for `:not_found`, `:content_too_large`, `:content_corrupt`, and `{:invalid_destination, reason}`; `:transient` for `:permission_denied` and `:io_failure` |
| `:parse` | `INVALID_JSON`, `SCHEMA_MISMATCH`, `HASH_MISMATCH`, or `DESTINATION_MISMATCH`, from the `RawAgencyResponse.parse/1` reason | `:permanent` |
| `:publish_agencies`, `:publish_manifest` | `WRITE_FAILURE` | `:permanent` for `:record_too_large`; `:transient` for `:timeout`, `:unavailable`, and `:unknown_topic` |

A `:permanent` failure repeats on every call. The error codes are the dead-letter `ERROR_CODE` values decided in GOB-48. `Gobusgo.OneBusAway.BatchFailure` builds these failures for both processors.

The processor logs `info` `Agency batch published` with `destination`, `request_id`, and `agency_count` when it publishes. A failure returns to the caller unlogged; the trigger logs the decision it takes.

## Response trigger

`Gobusgo.OneBusAway.ResponseTrigger.handle/2` takes one consumed "response stored" record, with its topic, partition, offset, key, value, and headers, and returns once its outcome is final. It serves one dataset, named by two modules in its options: `:event`, with `dataset/0` and `decode/1`, and `:processor`, with `process/2`. The agency dataset is `RawAgencyResponse.StoredEvent` and `AgencyBatch`; the vehicle dataset is `RawVehicleResponse.StoredEvent` and `VehicleBatch`. The event module's `decode/1` validates the value; an event that is not JSON, does not match the schema, belongs to another dataset, or has another `type` is dead-lettered without an attempt (`INVALID_JSON`, `SCHEMA_MISMATCH`, `UNSUPPORTED_TYPE`). Otherwise each attempt runs the processor's `process/2` as a task with a 10-second deadline. `Gobusgo.OneBusAway.ResponseTrigger.Policy` is pure and decides what follows:

| Attempt outcome | While attempts remain | After the third attempt |
| --- | --- | --- |
| Published | Finished | Finished |
| `:transient` failure | Retry after a jittered delay of up to 500 ms, then 1,000 ms | Dead-letter with the failure's `error_code` and `EXHAUSTED_RETRY_CONDITION` |
| Deadline exceeded | Retry | Dead-letter as `TIMEOUT`, exhausted |
| Crashed | Retry | Dead-letter as `INTERNAL_ERROR`, exhausted |
| `:permanent` failure | Dead-letter at once with its `error_code` | — |

`Gobusgo.DeadLetter.record/1` builds the dead-letter record: the consumed key and value untouched, on the consumed topic's `.dead-letter` topic, with the consumed headers followed by `ERROR_CODE`, `ERROR_MESSAGE`, `RETRY_ATTEMPTS`, `EXHAUSTED_RETRY_CONDITION` (exhausted only), `ORIGINAL_TOPIC`, `ORIGINAL_PARTITION`, `ORIGINAL_OFFSET`, `CONSUMER_GROUP`, `FIRST_ATTEMPT_TIME`, and `LAST_ATTEMPT_TIME`. A dead-letter record that three publish tries do not store returns `{:error, {:dead_letter_unpublished, reason}}`.

The trigger logs at most one line per record: `warning` `Response trigger processed after retries`, `error` `Response trigger dead-lettered`, or `error` `Response trigger dead letter not published`, with `dataset`, `error_code`, `attempt_count`, `retries_exhausted`, `topic`, `partition`, `offset`, and, for a parsed event, `event_id`, `destination`, and `request_id`.

`Gobusgo.OneBusAway.ResponseTrigger.KafkaConsumer` is the Broadway pipeline the application runs once per dataset: on `oba.agencies-with-coverage.response-stored` as the consumer group `gobusgo.agency-processor`, and on `oba.vehicles-for-agency.response-stored` as `gobusgo.vehicle-processor`, each starting from the earliest record when the group has no offset. It acknowledges a record that is processed or dead-lettered. For a record whose dead-letter record is not published it kills its own processor, the only way to leave a Broadway Kafka message unacknowledged: the partition's committed offset stays before that record, and the record is delivered again when the group next assigns the partition.

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

Schedule deviation and next stop, observed on 2026-10-06 in the newest stored response of each of the 12 agencies (2,448 vehicles, 1,189 with a trip status; three agencies had no vehicle), with the types checked in 1,440 stored responses of 2026-10-04 to 2026-10-06 (119,746 trip statuses). The documentation gives `scheduleDeviation` as "the deviation from the schedule in seconds, where positive number indicates the trip is running late and negative indicates the trips is running early", listed "if real-time arrival info is available", and `nextStop` and `nextStopTimeOffset` as the counterparts of `closestStop` and `closestStopTimeOffset` that always name the next stop, the offset being seconds from the vehicle's position to the stop among the trip's stop times, positive for a stop that is coming up (trip status element, checked 2026-10-06).

- Every trip status held all three: `scheduleDeviation` and `nextStopTimeOffset` as integers and `nextStop` as a non-empty string. The requester's schema requires those types, and reads an empty `nextStop` as none.
- `nextStop` was a stop of the response's own `references` in every trip status. Whether the stop view holds it was not checked.
- `scheduleDeviation` ran from -1,355 to 2,130 seconds, with the middle value 14 and nine in ten between -120 and 429.
- `nextStopTimeOffset` was zero or more in every trip status, up to 3,597 seconds, with the middle value 57. `closestStopTimeOffset` was negative for a stop already passed; `closestStop` was the same stop as `nextStop` in 629 trip statuses.
- A vehicle that has reported no location has both fields as well: of 256 such trip statuses, 207 had a `scheduleDeviation` of `0` and 49 another value, so the field is present whether or not the vehicle reports, and `0` does not tell a punctual vehicle from one with only schedule data. Of the 933 that had reported a location, 174 had `0`.
- `status` was `SCHEDULED` and `phase` `in_progress` in every trip status, so neither tells those vehicles apart.

In the test environment the configured publisher backend, `Gobusgo.Publisher.InProcess`, calls each view's `apply_records/2` with the records published to its state topic, tombstones left out. It calls `Gobusgo.OneBusAway.ResponseConsumer.consume/3` with the records published to each dataset's "response stored" topic. The consumer takes the dataset's event and processor modules, decodes each value with the event module, and calls the processor with the destination it names, in order, in the publishing process. A value that is not a "response stored" event of the dataset is skipped and counted in one `warning` `Response consumer skipped invalid events`; a stored response that fails to process is left failed, with no retry and no dead letter, and logged once at `error` `Response consumer failed` with `dataset`, `destination`, `stage`, `error_code`, and `class`.

`AgencyRecorder.record/2` publishes one "response stored" event once the writer has stored the response, with the `source` `/gobusgo/recorder/oba/agencies-with-coverage`, a new UUID version 7 as `id`, and the fetch time as `time`. A failed publish leaves the result `{:ok, recorded}` and logs `warning` `OneBusAway agency response recorded without its event` with the `reason` in place of the `info` line.

## Vehicle records and vehicle view

`Gobusgo.OneBusAway.VehicleBatch.process/2` takes the destination of one stored vehicle response, reads it through `Gobusgo.Reader`, validates it with `RawVehicleResponse.parse/1`, and publishes through `Gobusgo.Publisher`, in this order: the vehicle records, in calls of at most `Gobusgo.Publisher.record_count_max/0` records; the tombstones, in the same way; then the manifest, once every earlier call returned `:ok`. A success is `{:ok, %{destination: ..., agency_id: ..., request_id: ..., fetched_at: ..., vehicle_count: ..., tombstone_count: ...}}`, logged at `debug` as `Vehicle batch published`. A failure is the `BatchFailure` of the agency processor, with the stages `:read`, `:parse`, `:publish_vehicles`, `:publish_tombstones`, and `:publish_manifest`, and no manifest is published for it.

A tombstone is the vehicle's key with an empty value and no headers, built by `VehicleBatch.Records.tombstones/1`; a compacted topic deletes the key for it. The processor publishes one for each vehicle `VehicleView.expired_vehicle_ids/2` names: absent from the fetch being processed, and last seen more than five minutes before it. Nothing is stored for this beside the state topic, whose vehicle records carry the fetch time the view reads as "last seen". A vehicle that returns is published again under its key, which supersedes the tombstone. The five minutes are a decision recorded in GOB-87 and are not measured against the live feed.

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
| `routeId` | The route of that trip |
| `routeShortName` | The short name of that route, such as a route number |
| `routeLongName` | The long name of that route |
| `tripHeadsign` | The destination the trip shows to riders |
| `position` | `lat` and `lon` of where the source places the vehicle now: an estimate, extrapolated or taken from the schedule when no fresh report exists |
| `orientation` | The direction that goes with `position`, in degrees |
| `lastKnownLocation` | `lat` and `lon` of the last location the vehicle reported |
| `lastKnownOrientation` | The last direction the vehicle reported, in degrees; also `0` for a vehicle that has reported no location |
| `lastUpdateTimeMs` | When the source last heard from the vehicle, milliseconds since the Unix epoch; `0` is the source's "never" |
| `lastLocationUpdateTimeMs` | When the vehicle last reported a location, milliseconds since the Unix epoch; `0` is the source's "never" and is kept apart from `null` |
| `predicted` | Whether the source has real-time data for the vehicle's trip; `true` also when the vehicle has reported no location |
| `scheduleDeviationSeconds` | How far the vehicle is from its trip's schedule, in whole seconds; positive is late, negative early |
| `nextStopId` | The stop the vehicle reaches next on its trip |
| `nextStopTimeOffsetSeconds` | The time from the vehicle's position to that stop among the trip's stop times, in whole seconds, as of the fetch |

The state topic also holds vehicle records that lack the keys of the last three fields, or of those and the four route fields; `Records.decode/1` returns each missing key as `null`, so a view holds every field for every vehicle.

The source's update times are kept apart from `fetchedAt`, which is when Gobusgo made the request.

`Gobusgo.OneBusAway.VehicleView` holds the vehicles of each agency's latest complete fetch in memory, and the vehicle test page at `/vehicles` reads it. It is a process registered under a name and a table of the same name, started with the publish-subscribe server it announces on; the application starts one named `Gobusgo.OneBusAway.VehicleView` on `Gobusgo.PubSub`, and `Gobusgo.Kafka.TopicSubscriber`, or `Gobusgo.Publisher.InProcess` under test, calls its `apply_records/2` with the record values of `oba.vehicles-for-agency.state`, tombstones left out. `Gobusgo.OneBusAway.VehicleView.State` holds the rules and is pure.

- A fetch belongs to one agency. It is complete when its manifest and every vehicle the manifest names have been applied, in either order. The view switches that agency to the fetch in one step and leaves every other agency's current fetch as it is.
- A record is ignored when its fetch is its agency's current one or is older than it, and when its fetch time or agency differs from the ones its fetch is held under. A fetch with the same fetch time and another request identifier replaces the agency's current one.
- At most 64 agencies have a current fetch, at most 32 incomplete fetches are held, the oldest forgotten first, and a fetch holds at most 5,000 vehicles. A switch forgets every held fetch of the same agency older than the new current one.
- An `apply_records/2` call that switches at least one agency announces once, after the table holds the new fetches, as `{:vehicle_view_switched, view}` to every process that called `subscribe/1`.
- `current/1` reads the table without calling the process and returns the current fetch of every agency, in agency identifier order, each with its own fetch time. It returns `[]` before a fetch is complete and while the view is not running.
- `current_request_ids/1` returns the request identifier of every agency's current fetch and reads no vehicle, and `current_fetch/2` returns one agency's current fetch or `nil`. A reader that follows the announcements uses these two, so a switch of one agency costs it one agency's fetch.
- The table is the only place that holds a current fetch. The process keeps a fetch's vehicles until the fetch is complete; `State.put/2` then returns the fetch as `{:switched, fetch}`, the process writes it to the table, and the state keeps the fetch's request identifier and fetch time.
- The view keeps when each vehicle of each agency was last seen: the newest fetch time among the vehicle's records, whether or not their fetch became current, for at most 20,000 vehicles an agency. `expired_vehicle_ids/2` reads those times without calling the process. A switch forgets the vehicles that have expired at the new current fetch, so the processor names an expired vehicle for the fetches up to that switch and for none after, and a tombstone that a failed run did not publish is published by the next run.
- With the view behind the topic, a vehicle is named as expired for more than one fetch, and each publishes its tombstone again. After a restart the view reads records the broker has not compacted away yet, so a vehicle tombstoned before the restart is tombstoned once more.
- An agency that is no longer fetched keeps its last fetch. The view starts empty and holds nothing across a restart.

Per `apply_records/2` call the view logs `info` `Vehicle view switched` with `agency_count` and `vehicle_count`; `warning` `Vehicle view skipped invalid records` with `invalid_count`; and `warning` `Vehicle view switch not announced` with `reason`.

## Vehicle filter

`Gobusgo.OneBusAway.VehicleFilter` is the vehicle adapter of the filter contract in `Gobusgo.Filter`, and is pure. Its fields are `agency`, the identifier of the agency whose fetch holds the vehicle, and `route`, the published vehicle's `routeId`, the route of its active trip. A vehicle whose `routeId` is `null` or absent has no route, so it matches no filter that names a route and still matches a filter that names its agency alone. `normalize/1` judges a raw filter under those fields. `keeps_agency?/1` says whether a filter can keep a vehicle of an agency, judged by the agency alone, so a caller can leave the fetch of another agency unread; a filter that names routes and no agency keeps every agency by that check, and the fetch has to be read. `keeps_route?/1` says whether a filter keeps a vehicle of an agency on a route, which is how a caller decides whether to draw a route an agency lists. `filter_fetch/1` returns one agency's fetch with only the vehicles a filter keeps, in the fetch's vehicle order, so a fetch none of whose vehicles match comes back with its request identifier and fetch time and no vehicle. A further field is one entry in the specification and one in `values/1`. On 2026-10-05 the stored `routes-for-agency` responses held 391 distinct route identifiers, none with a comma, the value separator of a query string, and the longest of 12 bytes; most have the form `<agency>_<number>`, and Sound Transit's include `40_SNDR_EV` and `40_2-SHUTTLE`. The decisions are recorded in GOB-113, GOB-114, GOB-144, and GOB-145.

## Route records and route views

The two route datasets share their topics, because both describe a route (decided in GOB-96). Each has a recorder, a stored form, an event, a processor, and a records module of its own, shaped like the vehicle dataset's.

| | Routes | Route paths |
| --- | --- | --- |
| Requester | `Routes` | `RoutePaths` |
| Recorder | `RouteRecorder.record/2`, `:agency_id` | `RoutePathRecorder.record/2`, `:route_id` |
| Stored form | `RawRouteResponse` | `RawRoutePathResponse` |
| Destination | `raw/oba/routes-for-agency/dt=<date>/agency=<agency>/` | `raw/oba/stops-for-route/dt=<date>/route=<route>/` |
| `meta` field | `agencyId` | `routeId` |
| Event | `RawRouteResponse.StoredEvent`, dataset `oba/routes-for-agency`, key `oba/routes-for-agency/<agency id>` | `RawRoutePathResponse.StoredEvent`, dataset `oba/stops-for-route`, key `oba/stops-for-route/<route id>` |
| Processor | `RouteBatch.process/2` | `RoutePathBatch.process/2` |
| Record | `RouteBatch.Records`, key `routes-for-agency/<agency id>`, `type` `gobusgo.agency.routes.processed.v1` | `RoutePathBatch.Records`, key `stops-for-route/<route id>`, `type` `gobusgo.route.path.processed.v1` |

Both events go to `oba.routes.response-stored` and both records to `oba.routes.state`. The identifier in a destination is escaped as the vehicle dataset escapes an agency.

**One record per fetch.** A routes record holds `agencyId` and `routes`, every route of the agency in identifier order with the fields the requester returns. A route path record holds `routeId`, the route's `polylines`, and its `stopGroupings` with each group's name, stop identifiers, and polylines; the stops the response references go into the stops record below. Both hold `dataSha256`, `destination`, `fetchedAt`, and `requestId`. A fetch is whole in its one record, so there is no manifest and a view holds no partial fetch. An agency's newest record replaces its earlier ones in the compacted topic, so a route the agency drops leaves with them. The largest records on 2026-10-05 were 36 KB for an agency's routes and 55 KB for a route path, against the publisher's limit of 1 MB.

**One consumer for both datasets.** `Gobusgo.OneBusAway.RouteDatasets` is the event module and the processor module the response trigger and the in-process consumer take for the shared event topic. `decode/1` returns what the event module of either dataset decodes, and `process/2` hands a destination to the processor whose destinations start with its prefix; a destination of neither is a permanent `DESTINATION_MISMATCH`. Its `dataset/0` is `oba/routes`, the name in the trigger's log lines. The consumer group is `gobusgo.route-processor`, and a record it gives up on goes to `oba.routes.response-stored.dead-letter`.

**Views.** `Gobusgo.OneBusAway.FetchView` holds the latest fetch of each identifier of one dataset, and `Gobusgo.OneBusAway.FetchView.State` holds its rules and is pure. The application starts two, registered as `Gobusgo.OneBusAway.RouteView` (at most 64 agencies) and `Gobusgo.OneBusAway.RoutePathView` (at most 5,000 routes); those two names are processes and tables, and no module has them.

- A view takes its dataset's records module in `:records`. That module's `decode/1` returns the fetch with its `:id`, `:request_id`, and `:fetched_at`, and `{:error, :unsupported_type}` for the other dataset's record, which the view passes over without counting it.
- A fetch replaces its identifier's current one unless it is the same request or older. The fetch of an identifier beyond the view's bound is ignored.
- `current/1` returns every fetch in identifier order, `current_fetch/2` one identifier's, and `fetch_times/1` the fetch time of each identifier without reading the fetches. All three read the table and return nothing while the view is not running.
- A call that switches at least one identifier announces `{:fetch_view_switched, view}` once to the processes that called `subscribe/1`.
- One `Gobusgo.Kafka.TopicSubscriber` reads `oba.routes.state` and hands each batch to both views through `FetchView.apply_records_to_each/2`, as the in-process publisher does under test. A subscriber per view on the one client left each view with the records of some partitions: 6 of 12 agencies and 261 of 391 paths against the local broker on 2026-10-05, and a route source that fetched the missing ones again on every run (GOB-143).

The paths of a route whose agency no longer lists it stay in the path view and in the topic; nothing removes them.

## Stop records and stop view

Stops have no request of their own: they are the stops a `stops-for-route` response references, which is every stop some route serves (decided in GOB-93 and GOB-97). Against `stop-ids-for-agency` on 2026-10-05, the 391 stored responses held 13,026 of the 13,167 stops of the 12 agencies; the 141 left serve no route, 134 of them entrances of Sound Transit stations.

`Gobusgo.OneBusAway.RoutePathBatch.StopRecords` is the published form of the stops in one fetch of a route's stops and paths, and is pure. `build/1` takes what `RawRoutePathResponse.parse/1` returns, the same input as the route path record.

| | Stops |
| --- | --- |
| Topic | `oba.stops.state` |
| Key | `stops-for-route/<route id>` |
| `type` | `gobusgo.route.stops.processed.v1` |
| `id` | `<requestId>/route-stops/<route id>`, another than the route path record's under the one `source` |
| `data` | `routeId`, `stops`, `parentStops`, `dataSha256`, `destination`, `fetchedAt`, `requestId` |

A stop holds `id`, `name`, `lat`, `lon`, `code`, `direction`, `locationType`, `parent`, `wheelchairBoarding`, and `routeIds`, with `null` for a `code`, `direction`, or `parent` the source sends empty. `decode/1` rejects a record in which a stop identifier is empty or appears twice in `stops` and `parentStops` together. The stops of the largest route on 2026-10-05 were 43 KB of JSON.

`Gobusgo.OneBusAway.StopView` holds the stops in memory, one entry per stop, and `Gobusgo.OneBusAway.StopView.State` holds its rules and is pure.

- A fetch replaces its route's current one by the rules of `FetchView.State`. A stop is held for as long as the current fetch of some route lists it, as a stop or as a parent stop, so a stop every route drops is removed and no tombstone exists.
- A stop that several routes list has the values of the latest fetch that supplied it, with that fetch's `request_id` and `fetched_at`. When the route that supplied them drops the stop, the values stay until another route's fetch supplies it again.
- The view takes `:route_count_max` and `:stop_count_max`. The fetch of a route beyond the first is ignored, and a fetch that would hold more stops than the second is refused whole and logged.
- `current/1` returns every stop in identifier order, `stop/2` one stop, `stop_ids/1` the identifiers alone, and `stop_count/1` their number. All four read the table and return nothing while the view is not running.
- A call that holds or removes at least one stop announces `{:stop_view_switched, view, change}` once to the processes that called `subscribe/1`. `change` holds `held_ids` and `removed_ids`, each identifier in one of them, so a subscriber reads the stops that changed and no others.

`RoutePathBatch.process/2` publishes the stops record after the route path record, in the one publisher call, and returns the `stop_count` of the stops and parent stops together. A call that fails at `:publish_route_path` can leave either record published; the trigger's next attempt publishes both again, and each view ignores the fetch it already holds. The topic has to exist before the application runs: without it every route path event fails as `:unknown_topic` and is dead-lettered after its attempts, with its path record published.

The application starts one view, registered as `Gobusgo.OneBusAway.StopView`, for at most 5,000 routes and 100,000 stops, and one `Gobusgo.Kafka.TopicSubscriber` that reads `oba.stops.state` into it; under test the in-process publisher hands the topic's records to the view. The vehicle page reads it.

Measured against the local broker on 2026-10-05: the processor published the records of the 391 stored responses in 4 seconds, and a view fed by a subscriber of `oba.stops.state` held 13,026 stops, 113 of them parent stops, in a table of 16.6 MB beside 4.1 MB of process memory.

A route's stops record stays in the topic after its agency stops listing the route, as its path record does, so the stops only that route lists stay in the view.

## Open stops and the arrival cycle

No scheduler can fetch the arrivals of every stop, so the arrival source fetches only the stops that are open, at its own pace: what riders look at decides which stops a cycle may fetch, and the cycle decides how many (decided in GOB-158).

`Gobusgo.OneBusAway.OpenStops` holds the stops that processes of this node have open. The application starts one, registered under the module's name. A process calls `open/2` when it shows a stop and `close/2` when it stops; the registry monitors each process that has a stop open, so a process that exits closes its stops. `stop_ids/1` returns the stops at least one process has open. `Gobusgo.OneBusAway.OpenStops.State` holds the rules and is pure.

- At most 2,000 stops are open and one process has at most 4 open. An opening beyond either bound returns `{:error, :stop_count_exceeded}` or `{:error, :opener_stop_count_exceeded}`.
- State is in memory and per node: a restart begins with no stop open, and with several instances each knows only its own pages' stops.
- Opening and closing log nothing, since a stop a process opens is what one rider looks at.

`Gobusgo.OneBusAway.ArrivalSchedule.due/1` is the pure function from the open stops, the fetch time each has in the arrivals view, and the time it is to the stops that are due: the stops with no fetch first, in identifier order, then the stops whose fetch is at least five minutes old, the oldest first.

`Gobusgo.OneBusAway.ArrivalCycle.run/2` is one run of the arrival source. It records the due stops through `Gobusgo.OneBusAway.ArrivalRecorder.record/2`, each in a task under the ingestion task supervisor, with the route cycle's rules for pace, budget, deadline, and failure.

- The source runs a cycle every five seconds and a cycle takes one due stop, so the source makes at most one request every five seconds and counts the other due stops as `deferred_count`. With every open stop due again after five minutes, that pace keeps 60 open stops fresh; beyond that each stop is refreshed less often.
- A cycle reads at most 2,000 open stops.
- It returns `{:ok, counts}` with `open_count`, `due_count`, `recorded_count`, `failed_count`, `skipped_count`, `deferred_count`, and `unannounced_count`, or `{:error, :nothing_recorded}` when stops are due and none is recorded.
- It logs one line per run with those counts and `failures`, and no stop identifier: `debug` `OneBusAway arrival cycle found nothing due`, `info` `OneBusAway arrival cycle finished`, `warning` `OneBusAway arrival cycle finished degraded`, and `error` `OneBusAway arrival cycle failed`.

## Arrival records and arrivals view

The arrivals at a stop go through the flow of the other datasets, one fetch whole in one record like a route path. The arrival source fetches the stops that processes have open, and no page opens one yet (GOB-160), so outside tests the view stays empty.

- **Stored form.** `Gobusgo.OneBusAway.ArrivalRecorder.record/2` stores one stop's response under `raw/oba/arrivals-and-departures-for-stop/dt=<date>/stop=<stop>/`, the stop written like a route in a route path's destination, with `stopId` in `meta`. `Gobusgo.OneBusAway.RawArrivalResponse` holds the stored form.
- **Event.** The recorder publishes the "response stored" event to `oba.arrivals.response-stored` under the key `oba/arrivals-and-departures-for-stop/<stop id>`, with `data.stopId`. The consumer group `gobusgo.arrival-processor` consumes the topic through the response trigger.
- **Record.** `Gobusgo.OneBusAway.ArrivalBatch.process/2` publishes one record to `oba.arrivals.state` under the key `arrivals/<stop id>`, of the type `gobusgo.stop.arrivals.processed.v1`, with the `source` `/gobusgo/processor/oba/arrivals-and-departures-for-stop`. `data` holds `stopId`, `arrivals`, `dataSha256`, `destination`, `fetchedAt`, and `requestId`. Each arrival holds the fields of the requester's arrival in camel case, times with an `Ms` suffix, every key present and a missing value `null`. A failed call fails at the stage `:publish_arrivals`.
- **View.** `Gobusgo.OneBusAway.ArrivalView` is a `Gobusgo.OneBusAway.FetchView` over `ArrivalBatch.Records`: the newest fetch per stop, read with `current_fetch/2` and announced as `{:fetch_view_switched, Gobusgo.OneBusAway.ArrivalView}`. It holds at most 2,000 stops.
- **Expiry.** The view is the one fetch view started with `:fetch_age_ms_max`, 40 minutes: a response covers the 35 minutes after its fetch. Each `apply_records/2` call first removes the fetches older than that by the view's clock and announces the removal, and a record of a fetch that old is ignored, so a rebuild from the topic holds only the fetches still of use. A view that receives no records keeps what it holds, so a reader judges a fetch by its `fetched_at`.
- **No tombstone.** A stop nobody opens again keeps its last record in the compacted topic, at most one per stop, and the view ignores it once it has expired.

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

- Stops: [`stop`](https://developer.onebusaway.org/api/where/methods/stop), [`stops-for-location`](https://developer.onebusaway.org/api/where/methods/stops-for-location), [`stops-for-agency`](https://developer.onebusaway.org/api/where/methods/stops-for-agency), [`schedule-for-stop`](https://developer.onebusaway.org/api/where/methods/schedule-for-stop)
- Routes: [`route`](https://developer.onebusaway.org/api/where/methods/route), [`routes-for-location`](https://developer.onebusaway.org/api/where/methods/routes-for-location)
- Arrivals: [`arrival-and-departure-for-stop`](https://developer.onebusaway.org/api/where/methods/arrival-and-departure-for-stop)

List-returning methods must follow the bounded-read contract (explicit bound, lazy async iterator). Check each method's page for its paging and `limitExceeded` behavior before implementing.

## Open items

1. Rate limits and `Retry-After` behavior are undocumented in the pages checked.
