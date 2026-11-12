# Core

`assets/js/core/` holds the logic the web page shares with the native apps of GOB-419: the readers of the routing snapshots, the packed container, and the trip path files, the router, the scheduled service, the page's offline answers, and the choice of what the offline bundle saves, with the assertions and the math they use. Every other module under `assets/js/` is the web's shell around it: the hooks, the DOM, storage, the network, and the streams. GOB-419 ports this directory to Rust, so it holds only what a port can translate one for one. `assets/AGENTS.md` maps each module and the check it runs.

## Rules

- **No async work.** No module here is async, awaits, makes or waits on a promise, imports dynamically, or reaches a global that starts work finishing later: `fetch`, a timer, a stream, the Cache API, IndexedDB. A module takes values and returns values, and the shell does the IO and hands the results in. `npm run --prefix tools/lint lint:core` enforces it with the rule in `tools/lint/rules/no_async_work.mjs`, after `npm ci --prefix tools/lint`, and CI runs it in its `core-lint` job.
- **Pure.** No module reads the DOM, storage, or a clock it is not handed.
- **Self-contained.** A module here imports only from this directory; the shell imports the core and never the reverse.
- **A query that needs files asks for them.** `routing_journeys.js` decides a journey query and fetches nothing (GOB-420): `startQuery` and `resumeQuery` each return the query's state, a plain value that holds no bytes, and its next step, the manifest entries of the files it needs or its answer. The caller fetches the files, holds their bytes for the query, and hands every file it holds to each resume; `assets/js/routing_driver.js` is the web's driver. `ROUND_COUNT_MAX` bounds the resumes and `FETCH_TIMEOUT_MS` the wait for one file, and the core checks each file against the manifest's size. `trip_path_files.js` plans the fetches of the trip path files and folds each result in the same way.
- **The gzip streams are expanded outside.** `packed_container.js` and `routing_names.js` read expanded bytes; `assets/js/packed_stream.js` and `assets/js/names_stream.js` expand a stored file with the browser's `DecompressionStream`, which a native app replaces with its own.

## Files

- `assert.js`: the assertions every module of the front end uses.
- `math/`: geodesy, angles, interpolation, polylines, color contrast, and the hot paths' checks.
- `routing_snapshot.js`, `routing_names.js`, `packed_container.js`, `trip_path.js`, and `trip_path_shard.js`: the readers of the published binary files and the names file.
- `routing_engine.js`, `routing_walk.js`, `routing_journeys.js`, `point_journeys.js`, and `trip_plan.js`: the router, its walks, its journey queries, journeys to a point, and the Trip tab's rules.
- `trip_path_files.js`, `scheduled_path.js`, `scheduled_service.js`, and `offline_answers.js`: which trip path files a vehicle's path takes, the scheduled vehicles and arrivals, and the page's answers while offline.
- `offline_bundle.js`: what the offline bundle saves and its status.

## Checks

The node checks under `test/scripts/` that `assets/AGENTS.md` ("Checks") lists cover each module. `npm run --prefix tools/lint check` lints code written out by hand to check that the rule still reports each kind of async work and passes over synchronous code, a generator, and a binding named like a global.
