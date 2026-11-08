# Routing engine experiment

A JavaScript connection scan engine over the routing snapshots the application publishes, with its correctness fixtures and benchmark (GOB-232). Nothing here ships: the release image, CI, and the application leave this directory alone.

## Decision

JavaScript (decided 2026-11-08). A Rust engine compiled to WebAssembly applied the same rules and returned the same frontiers on every fixture and on 200 real queries. It routed about two and a half to three times faster on desktop, but the JavaScript engine already answers within about 21 ms at the 95th percentile, which a rider never notices. That gain did not justify a second implementation in a second language, so the Rust engine was removed. The measurements below are from the comparison, before it was removed.

## Layout

- `engine/csa.js` is the engine. It reads the snapshot files of format version 1 (`lib/gobusgo/routing/AGENTS.md`).
- `engine/load.js` builds it from the stops file, the transfers file, and every connection chunk of one date.
- `fixtures/journeys.json` holds the correctness cases, written by hand as timetables and readable expected frontiers. `experiments/routing/test/fixtures.mjs` checks the engine against them.
- `bench/` holds the benchmark: `measure.js` is shared, `run.mjs` and `node.mjs` run it in node, and `index.html`, `browser.mjs`, and `serve.mjs` run it in a browser on the same network.
- `scripts/build_snapshot.exs` builds the benchmark data from stored responses through the application's own rebuild and build, and `scripts/browser_benchmark.exs` runs the browser page in a headless Chrome.

## Rules

A query names an origin stop, a destination stop, and a departure time, and gets the Pareto frontier over arrival time and changes: no journey kept has another that arrives at least as early with at most as many changes. The scan runs in rounds, each adding one ride, up to 6 rides. A rider boards on arrival at the origin or after a walk, and the snapshot's minimum transfer, 120 seconds, after leaving a vehicle. A rider stays aboard a trip once boarded. One walking link may leave the origin and one may follow each ride. Each round's journey joins the frontier only when it arrives strictly earlier than the round before. Each label keeps the leg that set it, and a walk keeps the ride it follows, so the legs read back are the ones the scan used.

Limits of the rules: a journey of more than 5 changes is not found; walks are not chained, and a walk follows a ride or the origin only; walking time is straight-line distance at 1.2 m/s.

## Running it

From the repository root, with stored `schedule-for-route` and `stops-for-route` responses under a data directory, such as one the application filled while its sources ran:

```sh
MIX_ENV=test mix run --no-start experiments/routing/scripts/build_snapshot.exs <data directory> experiments/routing/data <UTC time>
cd experiments/routing
node test/fixtures.mjs
node bench/run.mjs
```

## Comparison results

Measured 2026-11-08 on the 272 live schedules of 2026-11-07, a Saturday, standing in for three service dates. The benchmark date, 2026-11-08, includes the previous date's trips past midnight: 11,433 stops, 493,420 connections in 30 chunks, and 72,744 walking links. There were 200 seeded queries between random stops, leaving between 06:00 and 22:00. Both engines returned the same 201 journeys: 38 queries had none within 6 rides, the median journey took 150 minutes, and most had 2 to 4 changes.

| | JavaScript, node | WebAssembly, node | JavaScript, Chrome | WebAssembly, Chrome |
| --- | --- | --- | --- | --- |
| Cold start, files in memory to ready engine | 15.9 ms | 8.9 ms | 21.7 ms | 12.0 ms |
| Warm query, median | 8.4 ms | 3.1 ms | 8.9 ms | 3.0 ms |
| Warm query, 95th percentile | 20.1 ms | 8.0 ms | 21.4 ms | 7.7 ms |
| One query repeated, median | 2.1 ms | 0.5 ms | 2.3 ms | 0.5 ms |

Desktop: Apple silicon, macOS, node 24.21.0, and headless Chrome 157. The node figures are medians of 5 fresh processes, and the Chrome figures one page load. The date's files are 12.2 MiB, 5.1 MiB gzipped; the WebAssembly module was 12.6 KiB gzipped. No phone was measured.
