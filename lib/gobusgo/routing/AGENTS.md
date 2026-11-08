# Routing snapshots

A routing snapshot is the schedule of one service date in a packed form a connection scan reads in the browser: the JavaScript engine and the Rust engine compiled to WebAssembly that GOB-232 compares both read the same files. This directory prepares and publishes snapshots and nothing else: no routing algorithm, map integration, offline support, or live routing lives here (GOB-237). Read this before changing the format, the manifest, or how they are published.

## Source and coverage

A snapshot is built from the route schedule view, which holds each route's `schedule-for-route` response for the day before the UTC date, the UTC date, and the day after (GOB-240). One snapshot is built per service date the view holds (decided in GOB-237):

- **Coverage:** the trips of that service date, plus the trips of the previous service date that are still running after the date starts. OneBusAway gives stop times as seconds from the start of the service day, past 86,400 for a trip past midnight, and each schedule names the start of its day in `scheduleDate`, milliseconds since the Unix epoch. A previous-date trip's times move back by the difference of the two starts, 23 or 25 hours on a change of daylight saving time, and only its connections departing at or after the start of the date are kept. A snapshot of the earliest date the view holds has no previous date, which its manifest entry states.
- **Time zone:** the snapshot carries no zone name. `serviceDayStartMs` is the absolute instant of the date's start, from which a reader converts its query time; every agency the responses of 2026-11-07 reference, 11 of them, is `America/Los_Angeles`.
- **Calendar exceptions:** OneBusAway answers each date with the services that run on it, exceptions applied, so every trip a schedule holds runs on its date. Nothing here reads a calendar.
- **Transfers:** derived, because the source has none (`Gobusgo.Routing.Transfers`). A change of trip at one stop takes at least 120 seconds; a walking link joins two stops at most 400 m apart in a straight line, at 1.2 m/s rounded up to the second, and a stop keeps its 64 nearest links. The constants are in the manifest entry's `transferRules`, and a change to one is a change to the snapshot.
- **Display metadata and map geometry are not in a snapshot.** Stop names, route names, colors, and shapes come from the views the map already reads.

## Format, version 1

`Gobusgo.Routing.SnapshotFormat` writes and reads the files; `assets/js/routing_snapshot.js` reads them in the browser. Every number is little-endian. Every file starts with a 16-byte header: the magic `GBRT`, the format version as a `u16`, the kind as a `u16` (1 stops, 2 trips, 3 transfers, 4 connections), the record count as a `u32`, and a `u32` of zero.

| Kind | Record |
| --- | --- |
| Stops | identifier: `u16` byte length, UTF-8 bytes. Index is position, stops in identifier order. |
| Trips | identifier and route identifier, each `u16` length and UTF-8; `u8` service day offset, `0` this date, `1` the previous date. Ordered by offset, then identifier. |
| Transfers | 12 bytes: `u32` from stop, `u32` to stop, `u32` duration in seconds. Ordered by from stop, then to stop. |
| Connections | 24 bytes: `i32` departure and `i32` arrival in seconds from the date's start, `u32` departure stop, `u32` arrival stop, `u32` trip, `u16` sequence within the trip, `u8` flags (bit 0 boarding at the departure stop, bit 1 alighting at the arrival stop), `u8` zero. Ordered by departure, arrival, trip, sequence. |

The same trip identifier can appear twice, once per service day offset: they are two runs. A connection's sequence is its hop's position in the whole trip, so a previous-date trip's first kept connection need not have sequence 0.

The shared fixtures are in `test/fixtures/routing/v1/`: one file of each kind and `expected.json`, written from `Gobusgo.Test.RoutingSnapshotFixture` by `test/scripts/routing_snapshot_fixtures.exs`. The Elixir tests check that the records encode to the files byte for byte; `node test/scripts/routing_snapshot_reader.mjs` checks that the JavaScript reader decodes them to `expected.json`, and CI does not run it. A Rust reader is checked against the same files. A change to the format raises the version, writes a `v2` directory, and keeps `v1` while a reader of it exists.

## Files and manifest

`Gobusgo.Routing.Snapshot` splits a date's connections into chunks by the hour of their departure, about 30 a day, and gives the stop, trip, and transfer tables files of their own (decided in GOB-237). A reader fetches the chunks from the hour of its query onward and stops once a chunk departs after the best arrival it has found, which gives the answer reading the whole snapshot gives. Each file is stored through `Gobusgo.Writer` at `routing/snapshots/dt=<build date>/<kind>-<sha256>.bin`.

`GET /api/routing/manifest` answers the manifest from `Gobusgo.Routing.Snapshots`, with `cache-control: no-cache` and an `etag`, the SHA-256 of the body, and `304` to a request naming it. The manifest holds `formatVersion` and `snapshots`, one entry per service date in date order, each with `serviceDate`, `serviceDayStartMs`, `previousServiceDateIncluded`, `builtAt`, `sourceFetchedAt` (`oldest` and `newest`, the freshness of the schedules it was built from), the counts of routes, stops, trips, connections, and walking links, `transferRules`, `files` (`stops`, `trips`, `transfers`), and `connectionChunks`, each with `departureSMin`, `departureSMax`, and `count`. Every file entry has `path`, `byteSize`, and `sha256`.

The files are served under `/routing`: locally from `<GOBUSGO_DATA_DIR>/routing` by a `Plug.Static` plug, and with a bucket from the bucket through CloudFront, both cacheable for a year as immutable, since a file's address never holds other content. Binary payloads never travel over the LiveView socket; a page may hand a reader the manifest's address.

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
