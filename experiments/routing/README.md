# Routing engine experiment

Compares a JavaScript connection scan engine with a Rust engine compiled to WebAssembly, on the routing snapshots the application publishes (GOB-232). Nothing here ships: the release image, CI, and the application leave this directory alone, so deleting it removes the experiment and its Rust toolchain.

## Layout

- `engine/csa.js` is the JavaScript engine and `rust/src/lib.rs` the Rust one. Both read the snapshot files of format version 1 (`lib/gobusgo/routing/AGENTS.md`) and apply the same rules, comparison for comparison.
- `engine/load.js` builds each engine from the same files: the stops file, the transfers file, and every connection chunk of one date.
- `fixtures/journeys.json` holds the correctness cases, written by hand as timetables and readable expected frontiers. `experiments/routing/test/fixtures.mjs` checks both engines against them, and `experiments/routing/test/equivalence.mjs` checks that the engines agree on every benchmark query over real data.
- `bench/` holds the benchmark: `measure.js` is shared, `run.mjs` and `node.mjs` run it in node, and `index.html`, `browser.mjs`, and `serve.mjs` run it in a browser, a phone's included.
- `scripts/build_snapshot.exs` builds the benchmark data from stored responses through the application's own rebuild and build, and `scripts/browser_benchmark.exs` runs the browser page in a headless Chrome.

## Rules

A query names an origin stop, a destination stop, and a departure time, and gets the Pareto frontier over arrival time and changes: no journey kept has another that arrives at least as early with at most as many changes. The scan runs in rounds, each adding one ride, up to 6 rides. A rider boards on arrival at the origin or after a walk, and the snapshot's minimum transfer, 120 seconds, after leaving a vehicle. A rider stays aboard a trip once boarded. One walking link may leave the origin and one may follow each ride. Each round's journey joins the frontier only when it arrives strictly earlier than the round before. Each label keeps the leg that set it, and a walk keeps the ride it follows, so the legs read back are the ones the scan used.

Limits of the rules, deliberate for the comparison: a journey of more than 5 changes is not found; walks are not chained, and a walk follows a ride or the origin only; walking time is straight-line distance at 1.2 m/s.

## Running it

From the repository root, with stored `schedule-for-route` and `stops-for-route` responses under a data directory, such as one the application filled while its sources ran:

```sh
MIX_ENV=test mix run --no-start experiments/routing/scripts/build_snapshot.exs <data directory> experiments/routing/data <UTC time>
cd experiments/routing/rust && cargo build --release --target wasm32-unknown-unknown && cd ..
node test/fixtures.mjs
node test/equivalence.mjs
node bench/run.mjs
node bench/serve.mjs
```

`rust/rust-toolchain.toml` pins Rust 1.88.0 with the `wasm32-unknown-unknown` target, which rustup installs on first use. `cd rust && cargo test` checks the Rust reader against the shared format fixtures in `test/fixtures/routing/v1/`. `node bench/serve.mjs` prints an address for a phone on the same network. Open it, press Run, and copy the JSON it shows. It serves the benchmark's own files and nothing else of the repository.

## Results

Measured 2026-11-08. The data is the 272 live schedules of 2026-11-07, a Saturday, standing in for three service dates. The benchmark date, 2026-11-08, includes the previous date's trips past midnight: 11,433 stops, 493,420 connections in 30 chunks, and 72,744 walking links. There are 200 seeded queries between random stops, leaving between 06:00 and 22:00. Both engines return the same 201 journeys: 38 queries have none within 6 rides, the median journey takes 150 minutes, and most have 2 to 4 changes.

Correctness came first: all 21 fixture queries pass in both engines, and the 200 benchmark frontiers are identical.

| | JavaScript, node | WebAssembly, node | JavaScript, Chrome | WebAssembly, Chrome |
| --- | --- | --- | --- | --- |
| Cold start, files in memory to ready engine | 15.9 ms | 8.9 ms | 21.7 ms | 12.0 ms |
| Warm query, median | 8.4 ms | 3.1 ms | 8.9 ms | 3.0 ms |
| Warm query, 95th percentile | 20.1 ms | 8.0 ms | 21.4 ms | 7.7 ms |
| One query repeated, median | 2.1 ms | 0.5 ms | 2.3 ms | 0.5 ms |
| Memory | 12.0 MiB heap once loaded | 17.6 MiB linear memory | 62 MiB heap growth over the run | 17.6 MiB linear memory, 0.9 MiB heap growth |

Desktop: Apple silicon, macOS, node 24.21.0, and headless Chrome 157. The node figures are medians of 5 fresh processes, and node's memory is measured after a forced collection. The Chrome figures are one page load, the JavaScript engine first, and Chrome's heap growth spans the load and the queries with no forced collection, so it counts the garbage each query's labels leave. Sizes: the date's files are 12.2 MiB, 5.1 MiB gzipped; the WebAssembly module is 31.2 KiB, 12.6 KiB gzipped. Fetching the files from a local server took 27 ms, measured apart from the cold start.

Mobile device: not yet measured. The numbers come from running `bench/serve.mjs` on a phone.

## Recommendation

**Further investigation, narrowed to one measurement: the phone run.** On desktop WebAssembly routes about two and a half to three times faster, but JavaScript already answers within 22 ms at the 95th percentile. That is far inside an interactive response of 100 ms, so the gain is invisible to a rider there. The WebAssembly module adds 12.6 KiB to the download and starts faster than the JavaScript engine, so loading costs nothing. What WebAssembly costs is maintenance: a second implementation in a second language with its own toolchain, kept identical to the first. The fixtures make that possible to check but not free.

The decision rule for the phone run: if the JavaScript engine's 95th percentile stays under 100 ms, choose JavaScript and delete the Rust engine. If it goes over, choose WebAssembly, whose desktop margin of about two and a half times at the 95th percentile brings a JavaScript figure of up to 250 ms back under 100 ms. A phone over 250 ms needs a faster algorithm in either language. Desktop gives no reason to favor WebAssembly today.
