# Routing snapshots

A routing snapshot is the schedule of one service date in a packed form a connection scan reads in the browser: the engine in `assets/js/routing_engine.js`, which `assets/js/routing_journeys.js` loads (GOB-248). This directory prepares and publishes snapshots and nothing else: no routing algorithm, map integration, offline support, or live routing lives here (GOB-237). Read this before changing the format, the manifest, or how they are published.

## Source and coverage

A snapshot is built from the route schedule view, which holds each route's `schedule-for-route` response for the day before the UTC date, the UTC date, and the day after (GOB-240). One snapshot is built per service date the view holds (decided in GOB-237):

- **Coverage:** the trips of that service date, plus the trips of the previous service date that are still running after the date starts. OneBusAway gives stop times as seconds from the start of the service day, past 86,400 for a trip past midnight, and each schedule names the start of its day in `scheduleDate`, milliseconds since the Unix epoch. A previous-date trip's times move back by the difference of the two starts, 23 or 25 hours on a change of daylight saving time, and only its connections departing at or after the start of the date are kept. A snapshot of the earliest date the view holds has no previous date, which its manifest entry states.
- **Time zone:** the snapshot carries no zone name. `serviceDayStartMs` is the absolute instant of the date's start, from which a reader converts its query time; every agency the responses of 2026-11-07 reference, 11 of them, is `America/Los_Angeles`.
- **Calendar exceptions:** OneBusAway answers each date with the services that run on it, exceptions applied, so every trip a schedule holds runs on its date. Nothing here reads a calendar.
- **Transfers:** derived, because the source has none (`Gobusgo.Routing.Transfers`). A change of trip at one stop takes at least 120 seconds; a walking link joins two stops at most 400 m apart in a straight line, at 1.2 m/s rounded up to the second, and a stop keeps its 64 nearest links. The constants are in the manifest entry's `transferRules` (`minimumTransferS`, `walkRadiusM`, `walkSpeedMPerS`, `walkLinkCountPerStopMax`), and a change to one is a change to the snapshot. The browser applies the same rules to walk from the rider's position to the first stops, reading them from the manifest.
- **Stop positions:** from the stop view, one per stop of the stops file, so the browser can start a journey from the rider's position without sending it anywhere (decided in GOB-241). A stop the stop view does not hold has an unknown position, and no walking link.
- **Display metadata and map geometry are not in a snapshot.** Stop names, route names, colors, and shapes come from the views the map already reads.

## Format, version 2

`Gobusgo.Routing.SnapshotFormat` writes and reads the files; `assets/js/routing_snapshot.js` reads them in the browser. Every number is little-endian. Every file starts with a 16-byte header: the magic `GBRT`, the format version as a `u16`, the kind as a `u16` (1 stops, 2 trips, 3 transfers, 4 connections, 5 positions), the record count as a `u32`, and a `u32` of zero.

| Kind | Record |
| --- | --- |
| Stops | identifier: `u16` byte length, UTF-8 bytes. Index is position, stops in identifier order. |
| Trips | identifier and route identifier, each `u16` length and UTF-8; `u8` service day offset, `0` this date, `1` the previous date. Ordered by offset, then identifier. |
| Transfers | 12 bytes: `u32` from stop, `u32` to stop, `u32` duration in seconds. Ordered by from stop, then to stop. |
| Connections | 24 bytes: `i32` departure and `i32` arrival in seconds from the date's start, `u32` departure stop, `u32` arrival stop, `u32` trip, `u16` sequence within the trip, `u8` flags (bit 0 boarding at the departure stop, bit 1 alighting at the arrival stop), `u8` zero. Ordered by departure, arrival, trip, sequence. |
| Positions | 8 bytes per stop, in the order of the stops file: `i32` latitude and `i32` longitude in millionths of a degree, or `-2147483648`, the `i32` minimum, on both for a stop with no known position. A position outside ±90 or ±180 degrees, or unknown on one axis only, is refused. |

The same trip identifier can appear twice, once per service day offset: they are two runs. A connection's sequence is its hop's position in the whole trip, so a previous-date trip's first kept connection need not have sequence 0.

A position is held in microdegrees as an `i32` because that is a tenth of a meter, three orders of magnitude finer than the 400 m walking radius, and because ±180,000,000 fits an `i32` with room to spare: 8 bytes a stop, about 90 KB for 11,400 stops, where two doubles would take twice that. Whole numbers also encode and decode to the same value in both languages, so the shared fixtures compare them exactly.

Version 2 added the positions file and changed nothing in the other four kinds. Version 1 is not read anywhere: the JavaScript reader refuses it, and the offline bundles a browser saved under it are re-fetched from the manifest, whose paths all changed with the version.

The shared fixtures are in `test/fixtures/routing/v2/`: one file of each kind and `expected.json`, written from `Gobusgo.Test.RoutingSnapshotFixture` by `test/scripts/routing_snapshot_fixtures.exs`. The Elixir tests check that the records encode to the files byte for byte; `node test/scripts/routing_snapshot_reader.mjs` checks that the JavaScript reader decodes them to `expected.json`, and CI does not run it. A change to the format raises the version, writes a directory for the new version, and keeps the old one while a reader of it exists.

## Files and manifest

`Gobusgo.Routing.Snapshot` splits a date's connections into chunks by the hour of their departure, about 30 a day, and gives the stop, trip, transfer, and position tables files of their own (decided in GOB-237). A reader fetches the chunks from the hour of its query onward and stops once a chunk departs after the cutoff, the best arrival it has found plus a window; the journeys that arrive by the cutoff are those reading the whole snapshot gives (decided in GOB-241, below). Each file is stored through `Gobusgo.Writer` at `routing/snapshots/dt=<build date>/<kind>-<sha256>.bin`.

`GET /api/routing/manifest` answers the manifest from `Gobusgo.Routing.Snapshots`, with `cache-control: no-cache` and an `etag`, the SHA-256 of the body, and `304` to a request naming it. The manifest holds `formatVersion` and `snapshots`, one entry per service date in date order, each with `serviceDate`, `serviceDayStartMs`, `previousServiceDateIncluded`, `builtAt`, `sourceFetchedAt` (`oldest` and `newest`, the freshness of the schedules it was built from), the counts of routes, stops, trips, connections, and walking links, `transferRules`, `files` (`stops`, `trips`, `transfers`, `positions`), and `connectionChunks`, each with `departureSMin`, `departureSMax`, and `count`. Every file entry has `path`, `byteSize`, and `sha256`.

The files are served under `/routing`: locally from `<GOBUSGO_DATA_DIR>/routing` by a `Plug.Static` plug, and with a bucket from the bucket through CloudFront, both cacheable for a year as immutable, since a file's address never holds other content. Binary payloads never travel over the LiveView socket; a page may hand a reader the manifest's address.

## Routing in the browser

`assets/js/routing_journeys.js` routes from the files alone; no page imports it yet (GOB-248). Its rules, decided in GOB-241:

- **Fetching.** Every file goes through a function the caller hands in, which receives a path the manifest names and nothing else, so the rider's position never leaves the browser. Each fetch has 20 seconds, a file of another size than the manifest's `byteSize` is refused, and a manifest of another `formatVersion` or with more than 48 chunks is refused before anything is fetched. A refusal or a failed fetch is an outcome naming the file, never a throw.
- **Loading by window.** It fetches the four tables together, then the chunks from the one holding its departure onward, one at a time, routing after each. It stops before the first chunk whose `departureSMin` is past the cutoff, the earliest arrival found plus `WINDOW_SECONDS`, 45 minutes, and returns the frontier journeys arriving by the cutoff, fewest changes first, with the earliest marked. The scan reads connections from the departure onward and stops at the best arrival, so a journey arriving by the cutoff uses only connections departing before it, which the loaded chunks hold: the result is the whole snapshot's frontier cut at the cutoff, and `node test/scripts/routing_journeys_check.mjs` checks that over a truncated chunk set. A destination no journey reaches reads every chunk from the departure on.
- **A start from a position.** `assets/js/routing_walk.js` takes the stops within `walkRadiusM` of the position in a straight line, at most `walkLinkCountPerStopMax` of them, nearest first, each with its distance at `walkSpeedMPerS` rounded up to the second, from the positions file and the manifest's `transferRules`. The scan starts from each with its walk, and takes no walking link from them.
- **The service date of a departure.** `serviceDateAt` picks the latest snapshot whose `serviceDayStartMs` is at or before the departure, while a chunk departs at or after it. Past midnight that is the new date, whose snapshot holds the previous date's trips still running, so every trip running at the departure is in it. Before midnight it is the date then running, whose trips past midnight it holds; a journey that needs a trip of the next date, such as the first morning bus after the last night one, is found only once that date has started. A departure past a snapshot's last connection, with no later snapshot started, has no service date.

Measured on 2026-11-08 in node 24.21.0 on a development machine, over the snapshot of 2026-11-08 built from the 249 schedules stored that day: 4,801 stops, 258,714 connections in 30 chunks, 6.2 MB of chunks and 633 KB of tables, the positions file 38 KB. A stop-to-stop query that found a journey fetched 3 to 5 chunks, 1.1 to 2.3 MB with the tables, and answered in 7 to 30 ms from files on disk; a query whose destination no journey reached fetched every chunk after its departure, up to 4.6 MB, in up to 191 ms. A start from a position found its journey with 4 chunks, 2.0 MB, in 14 ms, and one whose destination no journey reached read 22 chunks, 5.9 MB, in 261 ms. Those schedules cover 4,801 stops, where the 272 of 2026-11-07 covered 11,433, so the figures are for part of the network.

## Publication

`Gobusgo.Routing.Snapshots.Build` runs every ten minutes wherever the sources are scheduled. For each held date it hashes the inputs, the request identifiers of the date's and the previous date's schedules and the stop view's positions, and passes over a date whose hash is that of its current entry built today. Otherwise it builds, writes every file, and only then records the entry, so the manifest never names a file that is not stored. A build on a later day writes the files again under that day, which keeps every named file inside the two days of `Gobusgo.RetentionPolicy` and the bucket's lifecycle rule. Vehicle positions never trigger a build: only a schedule fetch or a stop position changes the inputs.

The manifest is held in the process and starts empty on every start; the first build after a start, at the scheduler's first run, builds every date. Nothing is cached in memory beyond that manifest, and no store other than the writer's is used.

Measured on 2026-11-08 with the 272 live schedules of 2026-11-07 standing in for three dates: a build of the three took 2.6 s on a development machine and a check that built nothing 42 ms. A date with its previous date held 493,420 connections in 30 chunks, 11.8 MB of connection files and 5.0 MB gzipped, with a 97 KB stop table and a 480 KB trip table.

## Live-routing overlay

Live data is a later overlay on top of a snapshot, and none of it is built yet. A snapshot never changes: delays, cancellations, and revised stop times live in the overlay; vehicle positions stay on the map's update path and never reach routing data.

- **Compatibility.** An overlay names the snapshot it applies to by `serviceDate` and the SHA-256 of its trips file, since it addresses trips by index; an overlay for any other snapshot is ignored.
- **Freshness and expiry.** An overlay carries the time it was built and an expiry. A reader applies an overlay only before its expiry, and once it expires or is missing the reader routes on the scheduled times alone, which is always a valid answer.
- **Ordering.** A connection scan needs connections in departure order. Applying a delay can move a connection past others, so an overlay is applied by producing a re-ordered set of connections, never by changing times in place.
- **Transfer feasibility.** A delayed arrival can make a planned transfer miss its connection, and an earlier one can make a missed transfer possible. The scan's minimum transfer time and walking links apply to the live times, so feasibility is decided after the overlay is applied.
