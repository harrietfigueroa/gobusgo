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

`SECRET_KEY_BASE` signs the browser session. Leave it unset in development and test: a random secret is generated at each start, so restarting the server makes open pages reload. Production refuses to start without it; generate one with `mix phx.gen.secret`. A value shorter than 64 bytes stops the application at startup.

## Running the server

```sh
mix phx.server
```

Open http://127.0.0.1:4000/ for the front end. In development the server also rebuilds the assets when a file under `assets/` or `lib/gobusgo_web/` changes.

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

With an API key, `Gobusgo.OneBusAway.AgencyRecorder.record/2` stores a live response, and its `destination` goes to `AgencyBatch.process/2` the same way.

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

`Gobusgo.OneBusAway.AgencyBatch.process/2` processes the stored response at one destination and publishes it through `Gobusgo.Publisher`: one record per agency, then one manifest record that completes the fetch. `Gobusgo.OneBusAway.Reconciliation.republish/2` publishes a "response stored" event again for every stored response fetched inside a time range. Neither needs an API key. The configured publisher backend delivers records inside the running application: agency and manifest records go to the in-memory view the REST API reads. It has no subscriber for "response stored" events, so reconciliation needs a backend passed in `:publish_options`, as its tests do.

```elixir
{:ok, result} = Gobusgo.OneBusAway.AgencyBatch.process(recorded.destination, [])
result.agency_count

publish_options = [backend: MyPublisher]

request = %{
  dataset: "oba/agencies-with-coverage",
  range: %{start_at: ~U[2026-10-02 00:00:00Z], end_at: ~U[2026-10-03 00:00:00Z]}
}

{:ok, %{published_count: published_count}} =
  Gobusgo.OneBusAway.Reconciliation.republish(request, publish_options: publish_options)
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
