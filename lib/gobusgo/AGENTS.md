# Application core

`lib/gobusgo/` holds the OTP application and what the sources, the views, and the pages share: settings, cadences and schedulers, the demand registry, usage records, storage, the publisher, the filter contract, the basemap extraction, and the start-memory check. This file also holds the data flow every dataset follows. The integrations have area files of their own beside their code: `one_bus_away/`, `gbfs/`, `routing/`, `s3/`, and `vendor_assets/`.

## Files

- `application.ex` is the OTP application entry point. It validates the HTTP listener, public host, ingestion, usage, shared vehicle, vehicle motion, and storage settings, and starts the S3 credentials process where a bucket is configured, the views, the GBFS processes, the demand registry, the usage recorder where usage is recorded, the request gate, the endpoint, the rebuilds of the route views and of the route schedule view where the sources are scheduled, and one scheduler per source and one for the cleanup of stored content.
- `config.ex` validates runtime settings as pure functions over the application environment. `config/one_bus_away.ex` is the struct of the OneBusAway settings, whose inspected form leaves the API key out.
- `cadence.ex` decides how often a poller polls, and is pure; see "Cadences and schedulers" below.
- `scheduler.ex` runs one source at its cadence, and `scheduler/state.ex` holds its cadence and backoff rules and is pure.
- `demand.ex` is the registry of what the node's processes want kept fresh, and `demand/state.ex` holds its rules and bounds and is pure.
- `usage.ex` records page connections; `usage/state.ex`, `usage/records.ex`, and `usage/user_agent.ex` are pure.
- `writer.ex`, `reader.ex`, and `deleter.ex` are the backend-neutral storage contracts, with local file backends under `writer/`, `reader/`, and `deleter/`, and S3 backends described in `s3/AGENTS.md`. `local_file/` holds what the local file backends share.
- `destination.ex` owns the logical destination and prefix rules that the writer and the reader share.
- `compression.ex` names the destinations that hold compressed content, those ending in `.gz`, and encodes and decodes gzip with a bound on the expanded size; it is pure.
- `retention.ex`, `cleanup.ex`, and `retention_policy.ex` delete stored content past its retention.
- `publisher.ex` is the backend-neutral contract for publishing records to topics, where a record with an empty value is a tombstone; `publisher/in_process.ex` is its in-process backend, which calls a subscriber per topic and stores nothing.
- `cloud_event.ex` encodes a CloudEvent 1.0 in structured mode and turns it into a publisher record.
- `canonical_json.ex` encodes compact JSON with sorted keys, the encoding of every stored file's content and every published event.
- `filter.ex` is the filter contract every kind of record shares, and is pure.
- `schema.ex` checks decoded data against a schema and returns the first mismatch as a value; `assert.ex` raises on it.
- `request_id.ex` builds the UUID version 7 request identifiers.
- `polyline.ex` encodes and decodes the encoded polyline format and is pure.
- `command.ex` runs an external command to its end or to a deadline, kills the command's process at the deadline, and returns the last 4,096 bytes of its output.
- `math/geodesy.ex`, `Gobusgo.Math.Geodesy`, holds the server's geodesy: the Earth's mean radius, which a test reads from `assets/js/math/geodesy.js`, the meters of a degree, π times the radius over 180, which every server caller uses (GOB-324), great-circle distance, and degrees and radians (GOB-322).
- `places/` builds and publishes the places file; read `places/AGENTS.md`.
- `basemap.ex` reads the manifest of the basemap directory, and `basemap/` plans and runs the extraction of the regional archives.
- `start_memory.ex` and `start_memory/fixture.ex` are the rules and the synthetic network of the start-memory check.
- `vendor_assets.ex` downloads the vendored front-end assets; read `vendor_assets/AGENTS.md`.
- `lib/mix/tasks/` holds the Mix tasks: `gobusgo.vendor.fetch`, `gobusgo.vendor.update`, `gobusgo.basemap.extract`, `gobusgo.places.build` (`places/AGENTS.md`), `gobusgo.start_memory`, `gobusgo.start_memory.fixture`, `gobusgo.assets.map_library`, and `gobusgo.assets.service_worker`. The two asset tasks are described in `assets/AGENTS.md`.

## Cadences and schedulers

`Gobusgo.Cadence` decides a poller's interval from a policy and the signals it is given, and reads no process and no clock. The policies are `{:fixed, interval_ms}`, which decides from no signals; `{:steps, steps_policy}`, a step table of at most eight steps from the count of viewers to an interval, which keeps the interval of one viewer for the policy's hold after the last viewer leaves; `{:proportional, parameters}`, the signal `item_count` times `item_spacing_ms` inside its bounds; and `{:on_demand, %{interval_ms: interval_ms}}`, which decides its interval while the signal `viewer_count` is one or more and pauses at zero.

`decision/2` returns `{:interval, interval_ms}` or `:paused`, and only a policy for which `pauses?/1` is true pauses; `interval_ms/2` is for a policy that never does. A steps policy's signals are the count of viewers and how long ago the count was last above zero, so the hold is decided with no clock. `assert_bounds/1`, `clamp/2`, and `interval_ms_min/1` hold the shortest and longest interval that a varying policy shares.

`Gobusgo.Scheduler` runs one source at its cadence, one run at a time, each run a task with a deadline. It ticks once a second, reads the source's signals in a process of its own under a short deadline, asks the cadence for the interval, and starts a run when the interval has elapsed since the last run started on the monotonic clock. After a signal read that fails it keeps the interval it has and counts the read.

A tick during a run starts nothing and counts the elapsed intervals as skipped, a run past its deadline is killed, and a failed run backs off for 1, 3, 7, then 15 intervals. Before a scheduler has read its signals it runs at its policy's shortest interval. `assert_spec/1` refuses a spec whose deadline is not under its policy's shortest interval.

A source whose policy pauses starts paused and starts no run while paused; once a read decides an interval again, the next tick starts a run when that interval has elapsed since the last run started, and at once after a start. The scheduler logs `Scheduler interval changed`, `Scheduler paused`, and `Scheduler resumed` at `info`, and nothing for a read that decides the interval it has.

The schedulers start only when the OneBusAway settings are present, and never under test. The OneBusAway sources and their cadences are in `one_bus_away/AGENTS.md` ("Scheduled sources"), and the shared vehicle source in `gbfs/AGENTS.md`.

## Demand registry

`Gobusgo.Demand` holds the `{dataset, item}` keys the node's processes register, each until its process releases it or exits. It answers which items of a dataset are held, how many processes hold a key, and how long ago a key last had a holder, on the monotonic clock it is started with; its state module takes the time of each release as a value.

A process that holds keys monitors the registry and registers again when the registry restarts. The registry is per node; how a page-serving instance tells an ingestion instance what is in demand is an open decision (GOB-154).

## Usage records

`Gobusgo.Usage` records page connections. A page registers its connection, the registration ends when the page's process exits, and the recorder writes the ended connections through the writer, at most once a minute and when it shuts down, as one compressed file under `usage/page-connections/dt=<date>/`. It logs `Usage records written` at `info` per file with the counts written and dropped, and `Usage records not written` at `error` for a write that fails, whose records it keeps.

A record names no visitor: it has no field for an address, a user agent, or an identifier. `usage/user_agent.ex` reduces a user agent to a device class and a browser family. A field added to a record needs its sentence in `GobusgoWeb.AppInfo.recorded/0`, which a test enforces. The page side, `GobusgoWeb.UsageHook` and `GobusgoWeb.ConnectionFacts`, is in `lib/gobusgo_web/AGENTS.md`.

## Storage

The writer, the reader, and the deleter are backend-neutral contracts with a local file backend each, under one base directory from `GOBUSGO_DATA_DIR`, and an S3 backend each where `GOBUSGO_S3_BUCKET` names a bucket (`s3/AGENTS.md`). `config/config.exs` and `config/runtime.exs` select the backends; nothing else names one.

The writer compresses the content of a `.gz` destination before the backend stores it, and the reader decompresses it. The reader also discovers destinations. The deleter removes a destination's content with whatever hierarchy below the request's `within` prefix that leaves empty.

A write may name `reader_keep_seconds`, how long a reader that fetches the content may keep it without asking again: the S3 backend stores it with the object, and the local backend, whose files have no place for it, stores the content alone (GOB-221).

## Retention and cleanup

`Gobusgo.Retention` judges from a destination alone whether its content is expired under a rule, a dataset's prefix and a count of days, by the `dt=<date>` segment after the prefix, so content is kept at least the rule's days and less than one day more. `Gobusgo.RetentionPolicy` names the days of each dataset and the spec of the cleanup's scheduler, which runs once an hour wherever the sources are scheduled.

`Gobusgo.Cleanup` is one bounded run that deletes each rule's expired content, the oldest day first, at most 20,000 deletions, and logs one line: `Stored content cleanup finished` at `info`, `Stored content cleanup finished degraded` at `warning` when a deletion or a discovery failed, or `Stored content cleanup failed` at `error`, with the counts and whether a backlog is left.

The retention of each dataset (decided in GOB-203, the tile archives in GOB-217, the shared vehicle files in GOB-258): one day for vehicle and arrival responses, three days for route schedule responses, 30 days for agency, route, and route path responses, three days for usage records, two days for tile archives, two days for routing snapshot files, and one day for shared vehicle files and their published files, as a backstop to the ten minutes `Gobusgo.Gbfs.VehicleStatusRetention` keeps both.

With a bucket configured the hourly cleanup is not scheduled: the bucket's lifecycle rules, in the infrastructure repository, hold the retention of what is in S3 with the same days, kept the same by hand (an open decision in the root file).

## Filter contract

`Gobusgo.Filter` normalizes a raw filter, as a transport decodes it, against the fields a kind of record names, returns every violation as a value, and decides whether a record's field values match a filter. Values of one field combine as OR and fields as AND. A kind of record takes part through an adapter, a module that names its fields and reads their values from one record: `Gobusgo.OneBusAway.VehicleFilter` is the vehicle adapter, with the agency and the route of the vehicle's trip as its fields. The vehicle page is the one caller; no REST route filters yet.

## Basemap extraction

`mix gobusgo.basemap.extract`, in `lib/mix/tasks/gobusgo.basemap.extract.ex`, cuts the regional basemap archives from a Protomaps build by hand; nothing schedules it. `Gobusgo.Basemap.ExtractPlan` plans the extraction and is pure, `Extractor` reads a stored agency response and runs the `pmtiles` command, and `Gobusgo.Basemap.Manifest` holds the manifest's rules and is pure. The endpoint serves the archives under `/basemap`.

With an offline zoom bound, 13 as decided in GOB-271 and set with `--offline-zoom-max`, the extractor also cuts each archive's offline extract, `basemap-<snapshot>-<number>-z<zoom>.pmtiles`, and the manifest names it beside its archive with its size and highest zoom. The README's "Basemap archives" section holds the process and the measured archive sizes.

## Start-memory check

`Gobusgo.StartMemory` holds the check's rules and is pure: the container's limits, production's 1,536 MiB and two CPUs, the cgroup's `anon` read from a `memory.stat` line, the start steps a log line names, and the verdict, which passes once `Routing snapshots built` and `Route stop tiles built` are logged with the peak at or under 700 MiB (GOB-341).

`Gobusgo.StartMemory.Fixture` is the synthetic network the check runs against, a function of the date alone, each response in its recorder's stored form after its requester's parser accepts it: 12 agencies and 390 routes over 11,290 stops, with two days of schedules. `mix gobusgo.start_memory.fixture <directory>` writes it under `<directory>/raw/`.

`mix gobusgo.start_memory --image <image>` copies the fixture, or the `raw/` of `--responses <directory>`, into a Docker volume, starts the image on it with production's limits, two schedulers, and no network, reads `anon` from inside the container, and fails on a peak past the threshold, a step that logs its failure, a kill for memory, an exit, or a deadline. The BEAM's own figures are not read, since its allocators keep freed segments that `:erlang.memory/0` does not count (GOB-278).

Measured on 2026-11-09 against the fixture on a development machine, a start peaked at 415 to 450 MiB with the VM's segment cache off and at 916 to 1,019 MiB with its default cache (GOB-283). The release runs with the default cache since the snapshot build reads one schedule at a time, and a start then peaked at 513 to 535 MiB (GOB-279).

## Data flow

Every dataset goes through one flow: a scheduler source runs a cycle, a recorder stores the raw response through the writer and publishes its "response stored" event, a processor reads the stored response and publishes its records to a state topic, and a view holds them for the pages. No dataset gets a request path of its own with a cache beside it (decided in GOB-158). A published record holds a CloudEvent 1.0 in structured mode, except a tombstone, which has an empty value.

The in-process publisher hands each "response stored" event to `Gobusgo.OneBusAway.ResponseConsumer`, which processes it in the publishing process with no retry, and hands each state topic's records straight to its view, so a scheduled fetch reaches its view before its recorder returns. `config/config.exs` names the subscribers.

Processed data is held in the in-memory views alone, and the application needs no broker in any environment (decided in GOB-183, which supersedes the Kafka decisions of GOB-43, GOB-47, GOB-48, GOB-49, and GOB-119). The views start empty on every start. After a start, the route views and the stop view are filled from the stored responses of the last two days, with no stored snapshot of a view (decided in GOB-203), and the route schedule view from those of its three service dates (GOB-240); everything else fills from the next fetch. The rebuilds are described in `one_bus_away/AGENTS.md`.

`Gobusgo.OneBusAway.RouteScheduleRebuild` reads eight responses at a time and processes as many at a time as the node has schedulers online, at most eight, since a decoded response is held whole while it is processed (GOB-276). It logs `Route schedule view rebuilt` at `info` or `Route schedule view rebuilt incomplete` at `warning`. The dates without service are not stored, so a start asks for them again.

The OneBusAway datasets, their topics, keys, views, cadences, and the arrivals of the open stops (GOB-158) are in `one_bus_away/AGENTS.md`. GBFS vehicle types take the flow with no recorder, since they are fetched again on their slot (GOB-257), and GBFS shared vehicles take the whole flow from a source that runs only while a page shows them (GOB-256); both are in `gbfs/AGENTS.md`. The routing snapshots are built from the views (`routing/AGENTS.md`), and the route and stop tile archive from the views (`lib/gobusgo_web/AGENTS.md`).

Raw responses, usage records, the route and stop tile archives, the routing snapshot files, the places file and its manifest under `places/`, and the shared vehicle files published to the browser are the only stored files (the archives decided in GOB-217, the published files in GOB-258). Nothing deletes `places/`: `Gobusgo.RetentionPolicy` has no rule for it, so an old places file stays until it is removed by hand (`lib/gobusgo/places/AGENTS.md`). An S3 mock is not part of the design.

Production uses production services, and local runs never touch production endpoints: configuration selects the target. GOB-19 holds the trigger definition and names the issues that hold the rest of the data flow's decisions.
