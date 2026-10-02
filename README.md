# Gobusgo

Gobusgo is an Elixir application that consumes the [OneBusAway API](https://developer.onebusaway.org/api/where/methods) for Sound Transit.

## Requirements

Erlang/OTP 29.1.1 and Elixir 1.20.4 (OTP 29), pinned in `.tool-versions`. The HTTP client is [Req](https://hex.pm/packages/req). The HTTP server is [Phoenix](https://hex.pm/packages/phoenix) on [Bandit](https://hex.pm/packages/bandit), and browser pages are [Phoenix LiveView](https://hex.pm/packages/phoenix_live_view). [Plug](https://hex.pm/packages/plug) is also what `Req.Test` uses in tests. Assets are built by [esbuild](https://hex.pm/packages/esbuild) and [Tailwind](https://hex.pm/packages/tailwind), which download their own binaries; Node.js is not needed.

## Setup

Install [mise](https://mise.jdx.dev) with Homebrew (`brew install mise`), then install the pinned toolchain from the repository root.

```sh
mise install
mix deps.get
mix assets.setup
mix assets.build
```

`mix assets.setup` downloads the esbuild and Tailwind binaries, and `mix assets.build` writes the JavaScript and CSS the pages load to `priv/static/assets/` (ignored by git).

## Configuration

Configuration is read from environment variables: `ONEBUSAWAY_BASE_URL` and `ONEBUSAWAY_API_KEY`. Copy the template to `.env` (ignored by git), fill in the values, and export them into your shell.

```sh
cp .env.example .env
set -a; source .env; set +a
```

The HTTP server listens on `GOBUSGO_HTTP_HOST`, an IPv4 or IPv6 address, and `GOBUSGO_HTTP_PORT`. Unset, they default to `127.0.0.1` and `4000`. A value that is not valid stops the application at startup.

`GOBUSGO_DATA_DIR` is the directory stored responses are written to and read from. Unset or blank, it is `data/` under the directory the server starts in; a relative value resolves against that directory.

`SECRET_KEY_BASE` signs the browser session. Leave it unset in development and test: a random secret is generated at each start, so restarting the server makes open pages reload. Production refuses to start without it; generate one with `mix phx.gen.secret`. A value shorter than 64 bytes stops the application at startup.

## Running the server

```sh
mix phx.server
```

Open http://127.0.0.1:4000/ for the front end. In development the server also rebuilds the assets when a file under `assets/` or `lib/gobusgo_web/` changes.

While the application runs with `ONEBUSAWAY_BASE_URL` and `ONEBUSAWAY_API_KEY` set, it fetches agency discovery once a minute and stores each successful response under `GOBUSGO_DATA_DIR`. With either one unset it starts without fetching and logs `OneBusAway sources not scheduled`. `Gobusgo.Scheduler.status(Gobusgo.OneBusAway.AgencyScheduler)` returns how the last fetch ended. Each stored response is announced by a "response stored" event and processed from it, so a scheduled fetch reaches the agency endpoints.

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

The agencies are held in memory and start empty. To see data without an API key, start the server in a shell with `iex -S mix phx.server` and process the test fixture as a stored response:

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

stored =
  Gobusgo.OneBusAway.RawAgencyResponse.build(%{
    response: response,
    request_id: Gobusgo.RequestId.generate()
  })

:ok = Gobusgo.Writer.write(Map.take(stored, [:destination, :content]), [])
{:ok, _result} = Gobusgo.OneBusAway.AgencyBatch.process(stored.destination, [])
```

```sh
curl http://127.0.0.1:4000/api/agencies
curl http://127.0.0.1:4000/api/agencies/40
```

With an API key, `Gobusgo.OneBusAway.AgencyRecorder.record/2` stores a live response and publishes its "response stored" event, which leads to the same processing with no further call.

## Running in Docker

The `Dockerfile` builds an image that runs the HTTP server as a release, for local development. It needs a container runtime with `docker` on the path; nothing else from Setup is required. Orchestration with the other local services lives in the infrastructure repository.

### Build

```sh
docker build --tag gobusgo:local .
```

The build downloads the dependencies and the esbuild and Tailwind binaries, so it needs network access. `.dockerignore` admits only `mix.exs`, `mix.lock`, `config/config.exs`, `config/runtime.exs`, `assets/`, and `lib/` into the build context, so `.env` and `data/` never reach the image.

### Start

The image is a production build, so it refuses to start without `SECRET_KEY_BASE`. Generate one into `.env` once (`mix phx.gen.secret`, or `openssl rand -base64 48` without Elixir installed), export the file as in Configuration, then start the container:

```sh
docker volume create gobusgo-data

docker run --detach --init --name gobusgo \
  --publish 127.0.0.1:4000:4000 \
  --mount type=volume,source=gobusgo-data,target=/data \
  --env SECRET_KEY_BASE \
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

Stored responses live in the `gobusgo-data` volume mounted at `/data`, so they outlast the container and an image rebuild. The agencies the API serves are held in memory and start empty; process a stored response to fill them. `bin/gobusgo rpc` evaluates an expression in the running server:

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
| `GET /api/agencies` answers `503` after a restart | The agencies are held in memory. Process a stored response again, as under Data. |
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

`Gobusgo.OneBusAway.AgencyRecorder.record/2` makes the same request and stores the successful response through `Gobusgo.Writer`. With the default configuration the local file backend writes it under `data/` (ignored by git), at `raw/oba/agencies-with-coverage/dt=YYYY-MM-DD/<fetchedAt>_<requestId>_<dataHash12>.json`. A failed request stores nothing.

```elixir
{:ok, settings} = Gobusgo.Config.one_bus_away()
{:ok, recorded} = Gobusgo.OneBusAway.AgencyRecorder.record(settings, [])
recorded.destination
```

`Gobusgo.OneBusAway.AgencyBatch.process/2` processes the stored response at one destination and publishes it through `Gobusgo.Publisher`: one record per agency, then one manifest record that completes the fetch. `Gobusgo.OneBusAway.Reconciliation.republish/2` publishes a "response stored" event again for every stored response fetched inside a time range. Neither needs an API key. The configured publisher backend delivers records inside the running application: agency and manifest records go to the in-memory view the REST API reads. A "response stored" event goes to the consumer that processes the stored response it names, so `record/2` and reconciliation both lead to the view; `:publish_options` passes another backend.

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

## Development

```sh
mix compile --warnings-as-errors
mix format --check-formatted
mix test
```

## Further reading

The OneBusAway integration contract is in [lib/gobusgo/one_bus_away/AGENTS.md](lib/gobusgo/one_bus_away/AGENTS.md). Engineering conventions are in [AGENTS.md](AGENTS.md).
