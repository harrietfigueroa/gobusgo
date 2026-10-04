# Gobusgo

Gobusgo is an Elixir application that consumes the [OneBusAway API](https://developer.onebusaway.org/api/where/methods) for Sound Transit.

## Requirements

Erlang/OTP 29.1.1 and Elixir 1.20.4 (OTP 29), pinned in `.tool-versions`. The HTTP client is [Req](https://hex.pm/packages/req). The HTTP server is [Phoenix](https://hex.pm/packages/phoenix) on [Bandit](https://hex.pm/packages/bandit), and browser pages are [Phoenix LiveView](https://hex.pm/packages/phoenix_live_view). [Plug](https://hex.pm/packages/plug) is also what `Req.Test` uses in tests. Assets are built by [esbuild](https://hex.pm/packages/esbuild) and [Tailwind](https://hex.pm/packages/tailwind), which download their own binaries; Node.js is not needed. Kafka is consumed through [BroadwayKafka](https://hex.pm/packages/broadway_kafka) and produced to through [brod](https://hex.pm/packages/brod). brod's checksum dependency compiles native code, which needs CMake and a C compiler: `.tool-versions` pins CMake, and the compiler comes from the Xcode command line tools on macOS or `build-essential` on Debian and Ubuntu.

## Setup

Install [mise](https://mise.jdx.dev) with Homebrew (`brew install mise`) and activate it in your shell, so that `mix` and `iex` are on your `PATH` inside the repository. For zsh, add the activation line to `~/.zshrc` and open a new terminal; the [mise documentation](https://mise.jdx.dev/getting-started.html) covers other shells.

```sh
echo 'eval "$(mise activate zsh)"' >> ~/.zshrc
```

Without activation, prefix a command with `mise exec --`, as in `mise exec -- mix test`.

Then install the pinned toolchain and build from the repository root.

```sh
mise install
mix deps.get
mix assets.setup
mix assets.build
```

`mix assets.setup` downloads the esbuild and Tailwind binaries and the vendored JavaScript packages (see [Vendored front-end assets](#vendored-front-end-assets)), and `mix assets.build` writes the JavaScript and CSS the pages load to `priv/static/assets/` (ignored by git).

## Configuration

Configuration is read from environment variables: `ONEBUSAWAY_BASE_URL` and `ONEBUSAWAY_API_KEY`. Copy the template to `.env` (ignored by git), fill in the values, and export them into your shell.

```sh
cp .env.example .env
set -a; source .env; set +a
```

The HTTP server listens on `GOBUSGO_HTTP_HOST`, an IPv4 or IPv6 address, and `GOBUSGO_HTTP_PORT`. Unset, they default to `127.0.0.1` and `4000`. A value that is not valid stops the application at startup.

`GOBUSGO_DATA_DIR` is the directory stored responses are written to and read from. Unset or blank, it is `data/` under the directory the server starts in; a relative value resolves against that directory.

`GOBUSGO_KAFKA_BOOTSTRAP_SERVERS` is a comma-separated `host:port` list of the Kafka brokers. Unset, it defaults to `localhost:9092`. A value that is not valid stops the application at startup.

`SECRET_KEY_BASE` signs the browser session. Leave it unset in development and test: a random secret is generated at each start, so restarting the server makes open pages reload. Production refuses to start without it; generate one with `mix phx.gen.secret`. A value shorter than 64 bytes stops the application at startup.

## Kafka

Outside the test environment the application needs a Kafka broker for its data flow: the recorder publishes a "response stored" event for each stored response, a consumer group processes each event and publishes the processed records to a state topic, and the in-memory agency view reads that topic from its earliest record on every start. Tests run with no broker.

The local broker is defined in the [infrastructure repository](https://github.com/harrietfigueroa/gobusgo-infra), and its `apply` also creates the topics below with their partitions and settings; its README covers start, stop, reset, and the topics. The broker listens on `localhost:9092`, and its automatic topic creation is off.

| Topic | Holds | Kept |
| --- | --- | --- |
| `oba.agencies-with-coverage.response-stored` | One "response stored" event per stored response | 7 days |
| `oba.agencies-with-coverage.response-stored.dead-letter` | The events the consumer gave up on, key and value untouched, with the failure in headers | 30 days |
| `oba.agencies-with-coverage.state` | One record per agency and one manifest per fetch | Compacted |
| `oba.vehicles-for-agency.response-stored` | One "response stored" event per stored vehicle response, keyed by agency | 1 day |
| `oba.vehicles-for-agency.response-stored.dead-letter` | The vehicle events the consumer gave up on, key and value untouched, with the failure in headers | 30 days |
| `oba.vehicles-for-agency.state` | One record per vehicle and one manifest per agency's fetch; a vehicle absent from its agency's fetches for more than five minutes gets a tombstone | Compacted |

The application starts whether or not the broker answers. While it is unreachable the HTTP server runs, the agency endpoints answer `503`, a recorded response stays stored with a `warning` that its event was not published, and the Kafka clients reconnect every 10 seconds, logging each failed attempt.

The consumer groups are `gobusgo.agency-processor` and `gobusgo.vehicle-processor`, one per event topic. An event that fails is retried in place, three attempts in all, and then goes to the dead-letter topic; read it with its headers:

```sh
docker exec gobusgo-kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic oba.agencies-with-coverage.response-stored.dead-letter --from-beginning --timeout-ms 10000 --formatter-property print.headers=true --formatter-property print.key=true
```

## Running the server

```sh
mix phx.server
```

Open http://127.0.0.1:4000/ for the front end. In development the server also rebuilds the assets when a file under `assets/` or `lib/gobusgo_web/` changes.

While the application runs with `ONEBUSAWAY_BASE_URL` and `ONEBUSAWAY_API_KEY` set, it fetches agency discovery once a minute and every agency's vehicles every five seconds, and stores each successful response under `GOBUSGO_DATA_DIR`. With either one unset it starts without fetching and logs `OneBusAway sources not scheduled`. `Gobusgo.Scheduler.status(Gobusgo.OneBusAway.AgencyScheduler)` returns how the last agency fetch ended, and `Gobusgo.Scheduler.status(Gobusgo.OneBusAway.VehicleScheduler)` how the last vehicle cycle did. Each stored response is announced by a "response stored" event and processed from it, so a scheduled fetch reaches the agency endpoints and the vehicle test page.

`GET /health` answers `200` with `{"status": "ok"}` while the server is running.

```sh
curl -i http://127.0.0.1:4000/health
```

Every error response under `/api` is an [RFC 9457](https://www.rfc-editor.org/rfc/rfc9457) problem details object, served as `application/problem+json` with `type`, `title`, `status`, and, where the error has a written explanation, `detail`. Elsewhere, an error is an HTML page for a request that accepts HTML first, such as a browser's, and problem details otherwise:

```sh
curl -i http://127.0.0.1:4000/nope
```

```json
{"detail":"No route matches GET /nope.","status":404,"title":"Not Found","type":"about:blank"}
```

To listen elsewhere, set the variables for the command:

```sh
GOBUSGO_HTTP_HOST=0.0.0.0 GOBUSGO_HTTP_PORT=8080 mix phx.server
```

### Agency endpoints

| Request | Response |
| --- | --- |
| `GET /api/agencies` | `200` with every agency of the latest processed fetch, sorted by identifier |
| `GET /api/agencies/:id` | `200` with one agency, or `404` problem details when the fetch holds no such agency |

Both answer `503` problem details with a `Retry-After` header until a fetch has been processed. A response body holds `data` and `meta`:

```json
{
  "data": [
    {
      "id": "1",
      "name": "Metro Transit",
      "url": "https://metro.example.test",
      "timezone": "America/Los_Angeles",
      "coverage": { "lat": 47.53009, "lon": -122.1462285, "latSpan": 0.681946, "lonSpan": 0.720787 }
    }
  ],
  "meta": { "count": 1, "fetchedAt": "2026-10-02T03:15:00Z", "requestId": "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10" }
}
```

`GET /api/agencies/:id` returns the one agency as `data`, and its `meta` holds `fetchedAt` and `requestId`. Every agency in a response comes from the fetch `meta` names.

The agencies are held in memory and are read back from the state topic on every start, so they are empty until a fetch has been processed. To see data without an API key, start the broker and the server in a shell with `iex -S mix phx.server`, store the test fixture as a response, and publish its "response stored" event:

```elixir
envelope =
  "test/fixtures/one_bus_away/agencies_with_coverage.json" |> File.read!() |> JSON.decode!()

response = %{
  agencies: [],
  envelope: envelope,
  fetched_at: DateTime.utc_now(),
  host: "oba.example.test",
  http_status: 200,
  method: "GET"
}

request_id = Gobusgo.RequestId.generate()

stored =
  Gobusgo.OneBusAway.RawAgencyResponse.build(%{response: response, request_id: request_id})

:ok = Gobusgo.Writer.write(Map.take(stored, [:destination, :content]), [])

event =
  Gobusgo.OneBusAway.RawAgencyResponse.StoredEvent.record(%{
    event_id: Gobusgo.RequestId.generate(),
    source: "/gobusgo/manual/oba/agencies-with-coverage",
    time: DateTime.utc_now(),
    response: %{
      destination: stored.destination,
      fetched_at: stored.fetched_at,
      data_sha256: stored.data_sha256,
      request_id: request_id
    }
  })

:ok = Gobusgo.Publisher.publish([event], [])
```

The consumer logs `Agency batch published` and the view logs `Agency view switched` within a few seconds; the first event after a start waits for the consumer group to form.

```sh
curl http://127.0.0.1:4000/api/agencies
curl http://127.0.0.1:4000/api/agencies/40
```

With an API key, `Gobusgo.OneBusAway.AgencyRecorder.record/2` stores a live response and publishes its "response stored" event, which leads to the same processing with no further call.

### Agency test page

http://127.0.0.1:4000/agencies lists the same agencies in a browser: each agency's identifier, name, website, time zone, and coverage area, with the fetch time and request identifier of the fetch they come from. It says "No agency data yet." until a fetch has been processed. The page updates on its own: open it first, run the snippet above in the `iex` shell, and the agencies appear without a reload.

### Vehicle test page

http://127.0.0.1:4000/vehicles lists the vehicles of every agency's latest fetch: each vehicle's identifier, agency, and trip, the position the source estimates for it, the location it last reported and when, whether the source has real-time data for it, and when the fetch was made. A field the source did not supply reads "Not supplied", and a vehicle that has never reported its location reads "No location reported". It says "No vehicle data yet." until a fetch has been processed, and updates on its own.

With the OneBusAway settings exported and the broker running, the server fetches every agency's vehicles every five seconds, so the page fills a few seconds after the first agency fetch and then follows the live feed. A vehicle missing from an agency's newest fetch leaves the page with that fetch and comes back with the fetch that holds it again.

Each response is stored under `raw/oba/vehicles-for-agency/dt=<date>/agency=<agency>/` in the data directory, compressed like the agency responses. A day of them is several gigabytes, and nothing deletes them yet.

## Running in Docker

The `Dockerfile` builds an image that runs the HTTP server as a release, for local development. It needs a container runtime with `docker` on the path; nothing else from Setup is required. Orchestration with the other local services lives in the infrastructure repository.

### Build

```sh
docker build --tag gobusgo:local .
```

The build downloads the dependencies and the esbuild and Tailwind binaries, so it needs network access. `.dockerignore` admits only `mix.exs`, `mix.lock`, `config/config.exs`, `config/runtime.exs`, `assets/`, and `lib/` into the build context, so `.env` and `data/` never reach the image.

### Start

The image is a production build, so it refuses to start without `SECRET_KEY_BASE`, and it publishes to and reads from Kafka. Start the local broker from the infrastructure repository first, which also creates the topics (see Kafka); the container joins the broker's `gobusgo` Docker network and reaches it as `kafka:19092`. Generate one into `.env` once (`mix phx.gen.secret`, or `openssl rand -base64 48` without Elixir installed), export the file as in Configuration, then start the container:

```sh
docker volume create gobusgo-data

docker run --detach --init --name gobusgo \
  --network gobusgo \
  --publish 127.0.0.1:4000:4000 \
  --mount type=volume,source=gobusgo-data,target=/data \
  --env SECRET_KEY_BASE \
  --env GOBUSGO_KAFKA_BOOTSTRAP_SERVERS=kafka:19092 \
  --env ONEBUSAWAY_BASE_URL \
  --env ONEBUSAWAY_API_KEY \
  gobusgo:local
```

`--env NAME` with no value passes the variable from the shell, so the credentials reach the container at run time and are never written to the image. The OneBusAway variables are needed only to make live requests; the server starts without them.

Open http://localhost:4000/ for the front end, and check the health endpoint from the host:

```sh
curl -i http://localhost:4000/health
docker inspect --format '{{.State.Health.Status}}' gobusgo
```

The image's health check requests `/health` inside the container, and the status reads `healthy` a second or two after the start.

| Setting in the image | Value | Meaning |
| --- | --- | --- |
| `GOBUSGO_HTTP_HOST` | `0.0.0.0` | The listener binds every interface of the container; `--publish 127.0.0.1:…` keeps it private to the host. |
| `GOBUSGO_HTTP_PORT` | `4000` | The port the container listens on. To use another host port, change the left side: `--publish 127.0.0.1:8080:4000`. |
| `GOBUSGO_DATA_DIR` | `/data` | The directory the writer stores raw responses in and the reader reads them from. |

### Data

Stored responses live in the `gobusgo-data` volume mounted at `/data`, so they outlast the container and an image rebuild. The agencies the API serves are held in memory and read back from Kafka's state topic when the server starts; a scheduled fetch or a processed response fills them. `bin/gobusgo rpc` evaluates an expression in the running server:

```sh
docker exec gobusgo find /data -type f

docker exec gobusgo /app/bin/gobusgo rpc '
  {:ok, settings} = Gobusgo.Config.one_bus_away()
  {:ok, recorded} = Gobusgo.OneBusAway.AgencyRecorder.record(settings, [])
  {:ok, result} = Gobusgo.OneBusAway.AgencyBatch.process(recorded.destination, [])
  IO.inspect(result.agency_count)
'
```

To process a file already on the volume, pass its path below `/data` to `AgencyBatch.process/2` as the destination.

### Stop

```sh
docker stop gobusgo
docker rm gobusgo
```

`docker stop` sends `SIGTERM`, and the release shuts its supervision tree down and exits with status `0`. The volume keeps its files; `docker volume rm gobusgo-data` deletes them. After a rebuild, remove the container and run the start command again.

### Troubleshooting

`docker logs gobusgo` shows the server's output, and `docker exec -it gobusgo /app/bin/gobusgo remote` opens an IEx shell in the running server.

| Symptom | Cause and fix |
| --- | --- |
| The container exits at once and the log holds `{:missing_setting, :secret_key_base}` | `SECRET_KEY_BASE` is unset or blank in the shell that ran `docker run`. Export `.env` and start again. |
| The log holds `{:invalid_setting, :secret_key_base}` | The secret is shorter than 64 bytes. |
| `curl` cannot connect, and the container is running | `GOBUSGO_HTTP_HOST` was overridden with a loopback address, which a published port cannot reach. Passing the whole `.env` with `--env-file` does this, because the file sets `127.0.0.1`. Pass the variables by name as above. |
| `docker run` fails with "port is already allocated" | Another process, such as `mix phx.server`, holds port 4000. Stop it or publish another host port. |
| The page loads and then keeps reloading, or the log holds "Could not check origin for Phoenix.Socket transport" | A production build accepts the LiveView socket only from pages on `localhost`. Open http://localhost:4000/, never http://127.0.0.1:4000/. |
| `GET /api/agencies` answers `503` after a restart | The state topic holds no fetch yet, or the container cannot reach the broker: check that it runs with `--network gobusgo` and `GOBUSGO_KAFKA_BOOTSTRAP_SERVERS=kafka:19092`, and that the topics exist. |
| Stored responses are missing after a restart | The container ran without the `--mount` flag, so `/data` was the container's own file system. |
| The build fails while downloading | The build stage has no network access, or a pinned base image is no longer published. |

## Usage

`Gobusgo.OneBusAway.Agencies.fetch/2` requests agency discovery (`agencies-with-coverage`) and returns each agency with its coverage area, or an error value. It writes nothing to disk. With the environment variables exported, run it in `iex -S mix`:

```elixir
{:ok, settings} = Gobusgo.Config.one_bus_away()
{:ok, agencies} = Gobusgo.OneBusAway.Agencies.fetch(settings, [])
Enum.map(agencies, & &1.name)
```

The module documentation lists every error value.

`Gobusgo.OneBusAway.AgencyRecorder.record/2` makes the same request and stores the successful response through `Gobusgo.Writer`. With the default configuration the local file backend writes it under `data/` (ignored by git), at `raw/oba/agencies-with-coverage/dt=YYYY-MM-DD/<fetchedAt>_<requestId>_<dataHash12>.json.gz`, compressed with gzip (`gunzip --stdout <file>` prints it). A response stored before compression keeps its `.json` name and is still read. A failed request stores nothing. After the write it publishes a "response stored" event; when that fails, the response stays stored and the call logs a `warning`.

```elixir
{:ok, settings} = Gobusgo.Config.one_bus_away()
{:ok, recorded} = Gobusgo.OneBusAway.AgencyRecorder.record(settings, [])
recorded.destination
```

`Gobusgo.OneBusAway.AgencyBatch.process/2` processes the stored response at one destination and publishes it through `Gobusgo.Publisher`: one record per agency, then one manifest record that completes the fetch. The Kafka consumer calls it for every "response stored" event; calling it by hand publishes the same records again, which the view ignores. `Gobusgo.OneBusAway.Reconciliation.republish/2` publishes a "response stored" event again for every stored response fetched inside a time range, and the consumer processes each one. Neither needs an API key.

```elixir
{:ok, result} = Gobusgo.OneBusAway.AgencyBatch.process(recorded.destination, [])
result.agency_count

request = %{
  dataset: "oba/agencies-with-coverage",
  range: %{start_at: ~U[2026-10-02 00:00:00Z], end_at: ~U[2026-10-03 00:00:00Z]}
}

{:ok, %{published_count: published_count}} =
  Gobusgo.OneBusAway.Reconciliation.republish(request, [])
```

The module documentation lists every result and error value.

## Basemap archives

The map pages read a self-hosted basemap: regional [PMTiles](https://docs.protomaps.com/pmtiles/) archives cut from a [Protomaps daily build](https://docs.protomaps.com/basemaps/downloads), one archive per region of agency coverage. Agencies whose coverage overlaps share an archive, and every coverage area is widened by 5,000 meters first. A basemap is refreshed by running the task below again with a newer build; nothing in the application runs it, so it is independent of the vehicle fetches.

`mise install` installs the `pmtiles` command at the version `mise.toml` pins. With a stored agency response under `data/` (see [Usage](#usage)), run:

```sh
mise exec -- mix gobusgo.basemap.extract \
  --response "raw/oba/agencies-with-coverage/dt=2026-10-03/<name>.json.gz" \
  --snapshot 20261004 \
  --output-dir data/basemap
```

- `--response` is the logical destination of the stored `agencies-with-coverage` response whose agencies decide the regions.
- `--snapshot` is the date of the build, `YYYYMMDD`. https://maps.protomaps.com/builds lists the builds; Protomaps keeps the builds of the past week and the latest build of each version.
- `--output-dir` receives `basemap-<snapshot>-<number>.pmtiles` per region and `manifest.json`, which records the build, the zoom range, each archive's bounds, size, and agencies, each agency's own bounds and archive, and the agencies skipped for having no coverage. `data/` is ignored by git.

The task downloads only the tiles inside each region, keeps every zoom of the build (0 to 15), and replaces an archive of the same name. `pmtiles show <archive>` prints an archive's header and `pmtiles verify <archive>` checks it.

Measured on 2026-10-04 with build `20261004` (Protomaps basemap 4.15.2) and the agency response fetched at 2026-10-03T19:10:46Z: the eleven agencies with coverage fall in one region, 46.888 to 48.643 north and -123.083 to -121.533 east, and Solid Ground EZ Loop is skipped for having none.

| Highest zoom | Archive size |
| --- | --- |
| 12 | 14 MB |
| 13 | 34 MB |
| 14 | 80 MB |
| 15 (the one extracted) | 189 MB (188,695,817 bytes, 43,063 tile entries) |

The sizes for zooms 12 to 14 come from `pmtiles extract --dry-run`. The basemap is an Open Database License produced work, so a page that shows it has to show the OpenStreetMap attribution.

### Serving the archives

The server serves the files of `<GOBUSGO_DATA_DIR>/basemap` (`data/basemap` by default, `/data/basemap` in the container) under `/basemap`: the archives and `manifest.json`. So an extraction with `--output-dir data/basemap` is served with no further step, and a refreshed basemap is published by extracting a newer build into that directory; `manifest.json` then names the new archives, and the old ones can be deleted.

A PMTiles reader fetches parts of an archive with HTTP `Range` requests. To check that against a running server:

```sh
curl --silent --dump-header - --output /dev/null --range 0-16383 http://127.0.0.1:4000/basemap/basemap-20261004-01.pmtiles
mise exec -- pmtiles show http://127.0.0.1:4000/basemap/basemap-20261004-01.pmtiles
```

The first answers `206 Partial Content` with `content-range: bytes 0-16383/<size>`, and the second prints the archive's header, read through range requests. A cache may keep an archive for an hour (`cache-control: public, max-age=3600`) and has to revalidate `manifest.json` on every use (`no-cache`); both carry an `etag`. The pages come from the same origin as the archives, so the server sets no CORS header.

## Development

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix test
```

`mix test` needs no broker and leaves out the tests tagged `kafka`. With the local broker running, run those as well; each creates and deletes topics of its own:

```sh
mix test --include kafka
```

`GOBUSGO_TEST_KAFKA_BOOTSTRAP_SERVERS` names another broker for them. CI runs them against a Kafka service container in its `kafka` job.

### Vendored front-end assets

The repository has no Node toolchain. The assets the pages use from other projects are downloaded at pinned versions into directories git ignores, and `assets/vendor.lock.json`, which is checked in, pins them. It holds two kinds of entry:

- A **package** is an npm package, pinned by version, with its tarball's address and SHA-512 and a SHA-256 for each file taken from it. The files are inputs of the asset build and go to `assets/vendor/`.
- An **archive** is a GitHub repository, pinned by commit, with the directories taken from it and a hash of their content. The files are served as they are, under `/vendor`, and go to `priv/vendor/`. The one archive is `basemaps-assets`, the fonts and sprites of the basemap (14 MB, 793 files).

```sh
mix gobusgo.vendor.fetch
```

downloads what the lock file pins and is part of `mix assets.setup`, so a fresh checkout, CI, and the image build all get the same files. It leaves an entry alone when its files are present with the pinned content, and refuses content whose hash differs from the lock file. The files are fetched when the assets are built, never when the application starts.

```sh
mix gobusgo.vendor.update                          # every package to its latest version
mix gobusgo.vendor.update pmtiles                  # one package to its latest version
mix gobusgo.vendor.update pmtiles --version 4.4.0  # one package to a given version, older or newer
mix gobusgo.vendor.update NAME --file PATH         # add a package, or change the files taken from one

mix gobusgo.vendor.update basemaps-assets --version COMMIT   # the archive to a given commit, older or newer
mix gobusgo.vendor.update NAME --version COMMIT --repository OWNER/NAME --directory DIRECTORY   # add an archive
```

rewrites the lock file and downloads the files. The change to commit is the lock file's diff. An archive has no "latest": it moves only to the commit `--version` names, all 40 hexadecimal digits, which https://github.com/protomaps/basemaps-assets/commits/main lists for the basemap's. After an update, run `mix assets.build` and check the pages that use the entry.

The archive of `basemaps-assets` holds 252 symbolic links, every one in the font `Noto Sans Devanagari Regular v1` and pointing at the same glyph range of `Noto Sans Regular`. A symbolic link is not downloaded, so that font has only the four glyph ranges it holds as files.

## Further reading

The OneBusAway integration contract is in [lib/gobusgo/one_bus_away/AGENTS.md](lib/gobusgo/one_bus_away/AGENTS.md). Engineering conventions are in [AGENTS.md](AGENTS.md).
