# Gobusgo

Gobusgo is an Elixir application that consumes the [OneBusAway API](https://developer.onebusaway.org/api/where/methods) for Sound Transit.

## Requirements

Erlang/OTP 29.1.1 and Elixir 1.20.4 (OTP 29), pinned in `.tool-versions`. The HTTP client is [Req](https://hex.pm/packages/req). The HTTP server is [Phoenix](https://hex.pm/packages/phoenix) on [Bandit](https://hex.pm/packages/bandit), and browser pages are [Phoenix LiveView](https://hex.pm/packages/phoenix_live_view). [Plug](https://hex.pm/packages/plug) is also what `Req.Test` uses in tests. Assets are built by [esbuild](https://hex.pm/packages/esbuild) and [Tailwind](https://hex.pm/packages/tailwind), which download their own binaries; Node.js is not needed.

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

`GOBUSGO_S3_BUCKET` names an S3 bucket that holds the stored responses and the usage records in place of that directory; the basemap archives stay in the directory. It needs `GOBUSGO_S3_REGION`, the bucket's region. `GOBUSGO_S3_PREFIX` is a key prefix that ends in `/`, empty when unset, and `GOBUSGO_S3_ENDPOINT` is the `https` address the bucket is reached at, `https://<bucket>.s3.<region>.amazonaws.com` when unset. The credentials are those of the role the container runs under, read from the address in `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`, which ECS sets; no setting holds a key. Leave the bucket unset in development and test. A value that is missing or not valid stops the application at startup. `lib/gobusgo/s3/AGENTS.md` holds the requests, the permissions the role needs, and what each S3 answer becomes.

`SECRET_KEY_BASE` signs the browser session. Leave it unset in development and test: a random secret is generated at each start, so restarting the server makes open pages reload. Production refuses to start without it; generate one with `mix phx.gen.secret`. A value shorter than 64 bytes stops the application at startup.

`GOBUSGO_PUBLIC_HOST` is the host name pages are served on, such as `localhost` or the name of a content delivery network in front of the server, in lowercase with no scheme, port, or path. With it set, the LiveView socket accepts a page of that host, under any scheme and port, and refuses a page of any other. Leave it unset in development and test, where the socket accepts every origin. Production refuses to start without it, and a value that is not a host name stops the application at startup.

## Data flow

The application needs no broker and no database. A recorder stores each response and publishes a "response stored" event; the event goes straight to the consumer in the same process, which processes the stored response and hands the processed records to the dataset's in-memory view. `config/config.exs` names the subscriber of every topic.

The views start empty on every start. Before the first route cycle the server processes the newest stored response of each agency's routes and of each route's stops and paths from the last two days, at most 60 seconds, and logs `Route views rebuilt` with the counts, or `Route views rebuilt incomplete` when a response or a listing failed. The rest fills from OneBusAway: the agencies on the first agency fetch, the vehicles on the first vehicle cycle after it, and each route item the stored responses did not supply within about ten minutes. The route source then refreshes each of those once a day. The agency endpoints answer `503` until the first agency fetch is processed.

A stored response that fails to process is logged once at `error` as `Response consumer failed`, and nothing retries it: the next fetch of the same data replaces it. A route item or an open stop whose response did not reach its view is fetched again when it is next due, the item at its daily slot and the stop after its refresh age.

## Running the server

```sh
mix phx.server
```

Open http://127.0.0.1:4000/ for the front end. In development the server also rebuilds the assets when a file under `assets/` or `lib/gobusgo_web/` changes.

While the application runs with `ONEBUSAWAY_BASE_URL` and `ONEBUSAWAY_API_KEY` set, it fetches agency discovery once a minute, every agency's vehicles every ten seconds while a vehicle page is connected and for a minute after the last one leaves, and once a minute otherwise, and each agency's routes and each route's paths once a day at a minute of their own, and stores each successful response under `GOBUSGO_DATA_DIR`. With either one unset it starts without fetching and logs `OneBusAway sources not scheduled`. `Gobusgo.Scheduler.status(Gobusgo.OneBusAway.AgencyScheduler)` returns how the last agency fetch ended, and `Gobusgo.Scheduler.status(Gobusgo.OneBusAway.VehicleScheduler)` how the last vehicle cycle did. Each stored response is announced by a "response stored" event and processed from it, so a scheduled fetch reaches the agency endpoints and the vehicle test page.

`GET /health` answers `200` with `{"status": "ok"}` while the server is running.

```sh
curl -i http://127.0.0.1:4000/health
```

`GET /ready` answers `200` with `{"status": "ready"}` once the views hold what a start fills them with: the agency view has a fetch, and every agency's routes and every listed route's paths have been fetched once. Before that it answers `503` problem details with `Retry-After` and a `detail` that names what is missing. A start with fresh views takes about ten minutes to get there. The daily refresh of a route leaves the answer at `200`.

```sh
curl -i http://127.0.0.1:4000/ready
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

The agencies are held in memory, so they are empty until a fetch has been processed. To see data without an API key, start the server in a shell with `iex -S mix phx.server`, store the test fixture as a response, and publish its "response stored" event:

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

The call returns once the response is processed: the processor logs `Agency batch published` and the view logs `Agency view switched` before it does.

```sh
curl http://127.0.0.1:4000/api/agencies
curl http://127.0.0.1:4000/api/agencies/40
```

With an API key, `Gobusgo.OneBusAway.AgencyRecorder.record/2` stores a live response and publishes its "response stored" event, which leads to the same processing with no further call.

### Agency test page

http://127.0.0.1:4000/agencies lists the same agencies in a browser: each agency's identifier, name, website, time zone, and coverage area, with the fetch time and request identifier of the fetch they come from. It says "No agency data yet." until a fetch has been processed. The page updates on its own: open it first, run the snippet above in the `iex` shell, and the agencies appear without a reload.

### Vehicle test page

http://127.0.0.1:4000/vehicles shows a map of the vehicles of every agency's latest fetch, with a filter by agency over one corner and an info button over another, and nothing else. The info button opens a panel that says what the application is, that it is an independent project no agency endorses, what each marker color means, how OneBusAway data is used and how often it is read, what the application records about a page connection, who provides the data and under which terms, and the licenses of the application and of the libraries the page uses. Each vehicle that has a position is a marker at the position the source estimates for it, colored by how far to trust that position: reported at most two minutes before the fetch, stale, schedule only for a vehicle that has never reported, or report time not supplied. A marker points the way the vehicle is heading when the source supplies a heading, and is labeled with its route where the map has room. Clicking a marker opens a popup with the vehicle, its status, its route and headsign, and its heading. Under the markers the map draws the path of every route of every agency as a thin line in the route's color, or in gray for a route that has no color; a route appears once the server has fetched its path, within about ten minutes of a first start or after `mix gobusgo.routes.backfill`. The map updates on its own.

The map is the basemap: the archive in the basemap directory (see [Basemap archives](#basemap-archives)), with the fonts and sprites that `mix assets.setup` downloads. It fits the whole archive, and `/vehicles?agency=<agency id>` fits one agency's coverage. The map shows the OpenStreetMap attribution. Before any extraction the page says "No basemap yet." and shows the info button and nothing else. A view wider than the archive shows a plain background beyond the tiles the archive holds.

With the OneBusAway settings exported, the server fetches every agency's vehicles every ten seconds while the page is open, so the page fills a few seconds after the first agency fetch and then follows the live feed. A vehicle missing from an agency's newest fetch leaves the page with that fetch and comes back with the fetch that holds it again.

Each response is stored under `raw/oba/vehicles-for-agency/dt=<date>/agency=<agency>/` in the data directory, compressed like the agency responses. A day of them is several gigabytes, and the cleanup deletes them after one day (see [Retention](#retention)).

## Running in Docker

The `Dockerfile` builds an image that runs the application as a release. This section runs it for local development, and CI publishes the same build from `main` (see Published image). It needs a container runtime with `docker` on the path; nothing else from Setup is required. Orchestration with the other local services lives in the infrastructure repository.

### Build

```sh
docker build --tag gobusgo:local .
```

The build downloads the dependencies and the esbuild and Tailwind binaries, so it needs network access. `.dockerignore` admits only `mix.exs`, `mix.lock`, `config/config.exs`, `config/runtime.exs`, `assets/`, and `lib/` into the build context, so `.env` and `data/` never reach the image.

### Start

The image is a production build, so it refuses to start without `SECRET_KEY_BASE` and `GOBUSGO_PUBLIC_HOST`. Generate the secret into `.env` once (`mix phx.gen.secret`, or `openssl rand -base64 48` without Elixir installed), export the file as in Configuration, then start the container:

```sh
docker volume create gobusgo-data

docker run --detach --init --name gobusgo \
  --publish 127.0.0.1:4000:4000 \
  --mount type=volume,source=gobusgo-data,target=/data \
  --env SECRET_KEY_BASE \
  --env GOBUSGO_PUBLIC_HOST=localhost \
  --env ONEBUSAWAY_BASE_URL \
  --env ONEBUSAWAY_API_KEY \
  gobusgo:local
```

`--env NAME` with no value passes the variable from the shell, so the credentials reach the container at run time and are never written to the image. `GOBUSGO_PUBLIC_HOST=localhost` is the host name of the address below; a page opened under another name, `127.0.0.1` among them, loads and has its socket refused. The OneBusAway variables are needed only to make live requests; the server starts without them.

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

Stored responses live in the `gobusgo-data` volume mounted at `/data`, so they outlast the container and an image rebuild. The agencies the API serves are held in memory and are empty when the server starts; a scheduled fetch or a processed response fills them. `bin/gobusgo rpc` evaluates an expression in the running server:

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
| The container exits at once and the log holds `{:missing_setting, :public_host}` | `GOBUSGO_PUBLIC_HOST` is unset or blank. Pass `--env GOBUSGO_PUBLIC_HOST=localhost` as above. |
| The log holds `{:invalid_setting, :public_host}` | `GOBUSGO_PUBLIC_HOST` is not a host name: it holds a scheme, a port, a path, or an uppercase letter. |
| A page loads and never updates, and the log holds "Could not check origin for Phoenix.Socket transport" | The page was opened under a host name other than `GOBUSGO_PUBLIC_HOST`. |
| `curl` cannot connect, and the container is running | `GOBUSGO_HTTP_HOST` was overridden with a loopback address, which a published port cannot reach. Passing the whole `.env` with `--env-file` does this, because the file sets `127.0.0.1`. Pass the variables by name as above. |
| `docker run` fails with "port is already allocated" | Another process, such as `mix phx.server`, holds port 4000. Stop it or publish another host port. |
| The page loads and then keeps reloading, or the log holds "Could not check origin for Phoenix.Socket transport" | A production build accepts the LiveView socket only from pages on `localhost`. Open http://localhost:4000/, never http://127.0.0.1:4000/. |
| `GET /api/agencies` answers `503` after a restart | The views are empty until the first agency fetch is processed, which needs `ONEBUSAWAY_BASE_URL` and `ONEBUSAWAY_API_KEY`: without them the log holds `OneBusAway sources not scheduled`. |
| Stored responses are missing after a restart | The container ran without the `--mount` flag, so `/data` was the container's own file system. |
| The build fails while downloading | The build stage has no network access, or a pinned base image is no longer published. |

### Published image

A merge to `main` publishes the image to GitHub Container Registry, once the other CI jobs pass on the merged commit. Of the commits merged while a run on `main` is in progress, only the newest gets a run, and so an image. CI's `publish` job builds it for `linux/arm64` and pushes it to `ghcr.io/harrietfigueroa/gobusgo` under one tag, the full SHA of the commit it was built from. No tag moves and there is no `latest`: a run that is started again leaves the tag of its commit as it is. The job's summary shows the image's digest.

The package is private. The job signs in with the workflow's own token and keeps the 10 newest images, deleting the older ones. To pull one, sign in with a personal access token that has the `read:packages` scope:

```sh
docker login ghcr.io --username <GitHub user name>
docker pull ghcr.io/harrietfigueroa/gobusgo:<commit SHA>
```

A pull request builds the image for the same platform and publishes nothing.

### Production release

While the repository variable `PRODUCTION_DEPLOY_ENABLED` is `true`, CI's `release` job follows `publish`: it asks the [infrastructure repository](https://github.com/harrietfigueroa/gobusgo-infra) to release the commit, by starting that repository's `Application release` workflow with the commit's SHA, and ends. A merge to `main` is then running in production about six minutes later, and the application is down for about a minute of that. The job's summary links the release's run, which is where a release that fails shows; the commit here stays green.

Pause the releases, and resume them:

```sh
gh variable set PRODUCTION_DEPLOY_ENABLED --body false
gh variable set PRODUCTION_DEPLOY_ENABLED --body true
```

While they are paused a merge publishes its image and releases nothing, and the `release` job shows as skipped. To take a bad commit out of production, pause, start the infrastructure repository's `Application deploy` workflow with the last good commit, fix or revert on `main`, and resume: the next merge is released.

The job signs in with the repository secret `PRODUCTION_RELEASE_TOKEN`, a fine-grained personal access token limited to the infrastructure repository with the Actions permission at write. The token expires. A job that fails with a 401 names it, and a new token goes in with `gh secret set PRODUCTION_RELEASE_TOKEN`.

A run that is started again for a commit that is no longer the head of `main` asks for no release.

## Usage records

The application stores one record each time a page disconnects, to count visits. A record holds when the page connected, for how long, which page it was (`vehicle`, `agency`, `home`), whether it was a page already open that connected again, the agencies and routes of the last filter the page showed, the device class (`mobile`, `tablet`, `desktop`, `bot`, `unknown`), the browser family, the range the window's width falls in, the browser's language without its region, and the host of the site that linked to the page. A record holds no IP address, no cookie, no identifier of a visitor, and no user agent, so the records of two visits cannot be told to be from one visitor. The vehicle page's info panel lists the same fields.

The records of the connections that ended in a minute are one gzip file under `usage/page-connections/dt=<date written>/` in the data directory: a JSON object with `meta` and `records`. A minute in which no connection ended writes no file, and the application writes what it holds when it shuts down. A crash loses the records not yet written and the connections open at that moment. The cleanup deletes these files after three days (see [Retention](#retention)), and they cannot be fetched again, so counts over a longer time have to be copied out before then.

A phone that sleeps reopens its connection, so a visit is a record whose `reconnect` is `false`. This counts the visits of each day, crawlers left out:

```sh
find "$GOBUSGO_DATA_DIR/usage/page-connections" -name '*.json.gz' -exec gunzip --stdout {} + |
  jq --slurp '[.[].records[] | select(.reconnect == false and .deviceClass != "bot")]
    | group_by(.connectedAt[0:10])
    | map({date: .[0].connectedAt[0:10], visits: length})'
```

The server logs `Usage records written` once per file, with the count of records in it and the counts its bounds dropped. Under test nothing is recorded.

## Retention

Once an hour the server deletes the stored files that are past their dataset's retention. A file belongs to the UTC date in its path, `dt=<date>`, and is deleted once that date is more than the dataset's days before today, so it is kept at least that many days and less than one day more.

| Files | Kept |
| --- | --- |
| `raw/oba/vehicles-for-agency/` | 1 day |
| `raw/oba/arrivals-and-departures-for-stop/` | 1 day |
| `raw/oba/agencies-with-coverage/` | 30 days |
| `raw/oba/routes-for-agency/` | 30 days |
| `raw/oba/stops-for-route/` | 30 days |
| `usage/page-connections/` | 3 days |

With a bucket configured the server schedules no cleanup: the bucket's lifecycle rules, which the infrastructure repository declares with the same days, expire its objects. A run deletes at most 20,000 files, the oldest first, and leaves the rest to the next run. It logs `Stored content cleanup finished` with the counts it deleted and failed to delete and whether a backlog is left. The first run starts with the server, so a data directory that holds older files loses them then. A directory that a deletion leaves empty is removed, up to the dataset's own. Under test nothing is scheduled. Reconciliation over a time range whose files are deleted publishes nothing and reports a count of 0.

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

`Gobusgo.OneBusAway.AgencyBatch.process/2` processes the stored response at one destination and publishes it through `Gobusgo.Publisher`: one record per agency, then one manifest record that completes the fetch. The response consumer calls it for every "response stored" event; calling it by hand publishes the same records again, which the view ignores. `Gobusgo.OneBusAway.Reconciliation.republish/2` publishes a "response stored" event again for every stored response fetched inside a time range, and the consumer processes each one. Neither needs an API key.

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

`mix test` needs no broker and no network access.

### Memory of the vehicle page

Two measurements print the memory the page at `/vehicles` holds, with one fetch cycle of synthetic vehicles in the counts a real cycle had, synthetic routes and paths in the counts of a real day, and twelve further cycles while the page is open. Each reading is given as found and again after a forced collection, so the difference is garbage that was still held.

```sh
mix test --only memory
```

prints the memory of the page process, of the vehicle view process, and of the view's table.

```sh
mix assets.build
MIX_ENV=test GOBUSGO_DATA_DIR=<base directory with a basemap> \
  mix run --no-start test/scripts/vehicle_page_browser_memory.exs <path of the Chrome executable>
```

prints the page's JavaScript heap, the heaps of its workers, and its count of DOM nodes in a headless Chrome. The map's memory on the graphics side is not read. A process's heap grows in steps, so the server readings move in steps too, and a reading as found depends on when the last collection ran.

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

The packages are `maplibre-gl`, which draws the map; `pmtiles`, which reads tiles out of an archive with range requests, and `fflate`, which `pmtiles` imports; and `@protomaps/basemaps`, the basemap's style. `maplibre-gl` starts a worker from a file beside its own, so `mix assets.build` copies its three module files to `priv/static/assets/vendor/maplibre-gl-<version>/` as they are, and the page loads them from there. The directory carries the version the lock file pins, so an update of `maplibre-gl` changes the address of all three files and leaves the earlier version's addresses as they were; the other packages are bundled into `app.js`.

The archive of `basemaps-assets` holds 252 symbolic links, every one in the font `Noto Sans Devanagari Regular v1` and pointing at the same glyph range of `Noto Sans Regular`. A symbolic link is not downloaded, so that font has only the four glyph ranges it holds as files.

## Further reading

The OneBusAway integration contract is in [lib/gobusgo/one_bus_away/AGENTS.md](lib/gobusgo/one_bus_away/AGENTS.md). Engineering conventions are in [AGENTS.md](AGENTS.md).
