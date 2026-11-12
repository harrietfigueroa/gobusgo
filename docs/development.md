# Development

Engineering conventions are in [AGENTS.md](../AGENTS.md), and each area of the code has an `AGENTS.md` of its own beside it, which the root file maps.

## Setup

Erlang/OTP and Elixir are pinned in `.tool-versions` and installed with [mise](https://mise.jdx.dev). Install it (`brew install mise`) and activate it in your shell, or prefix commands with `mise exec --`.

```sh
echo 'eval "$(mise activate zsh)"' >> ~/.zshrc   # then open a new terminal
mise install
mix deps.get
mix assets.setup    # esbuild, Tailwind, and the vendored front-end packages
mix assets.build    # writes priv/static/assets/
```

Node is needed only for the checks under `test/scripts/` and `tools/lint/`.

## Configuration

Settings are environment variables. Copy the template, fill it in, and export it:

```sh
cp .env.example .env
set -a; source .env; set +a
```

| Variable | Meaning |
| --- | --- |
| `ONEBUSAWAY_BASE_URL`, `ONEBUSAWAY_API_KEY` | The transit data source. Without them the server starts and fetches nothing. |
| `GOBUSGO_HTTP_HOST`, `GOBUSGO_HTTP_PORT` | Where the server listens, `127.0.0.1` and `4000` by default. `0.0.0.0` lets a phone on the same network connect. |
| `GOBUSGO_DATA_DIR` | Where responses, usage records, and published files are stored, `data/` by default. |
| `GOBUSGO_FILE_ORIGIN` | Another origin to fetch the routing, trip path, places, address, and intersection files from. See [running against production](../README.md#running-locally-against-production). |
| `SECRET_KEY_BASE` | Signs the browser session. Leave unset in development, where each start makes a random one. |
| `GOBUSGO_PUBLIC_HOST` | The host name pages are served on. Leave unset in development. |
| `GOBUSGO_DONATION_URL` | The address of the donation button. Unset, no button is shown. |
| `GOBUSGO_VEHICLE_MOTION_*` | The zoom band, vehicle count, and frame rates of smooth vehicle motion. Empty means the defaults. |

A value that is not valid stops the application at start, naming the setting. Never commit `.env`; the OneBusAway key travels in a query string, so keep it out of logs and error output too.

## Running

```sh
mix phx.server
```

Open <http://127.0.0.1:4000/vehicles>. The server rebuilds the assets when a file under `assets/` or `lib/gobusgo_web/` changes. A fresh start fills its views within about ten minutes; the map needs a [basemap](#basemap) to draw anything.

## Checks

Run these before calling work done:

```sh
mix format            # also rewrites code through Quokka; read its diff
mix compile --warnings-as-errors
mix format --check-formatted
mix test
```

`mix test` needs no network. [AGENTS.md](../AGENTS.md) lists the further checks a change to the stylesheet, the front end, the OpenAPI documents, or the Docker image runs.

## Docker

The `Dockerfile` builds the application as a release, the same build a production image uses.

```sh
docker build --tag gobusgo:local .
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

The image is a production build, so it needs `SECRET_KEY_BASE` (generate one with `mix phx.gen.secret` and put it in `.env`) and `GOBUSGO_PUBLIC_HOST`. Open <http://localhost:4000/>; a page opened as `127.0.0.1` has its live connection refused, because that is not the configured host. `docker logs gobusgo` shows the output, `docker exec -it gobusgo /app/bin/gobusgo remote` opens a shell in the running server, and `docker stop gobusgo && docker rm gobusgo` ends it. Pass variables by name as above rather than with `--env-file .env`, whose `127.0.0.1` host leaves the published port unreachable.

## Basemap

The map reads a self-hosted basemap: a [PMTiles](https://docs.protomaps.com/pmtiles/) archive cut from a [Protomaps daily build](https://docs.protomaps.com/basemaps/downloads) to the agencies' coverage. `mise install` installs the `pmtiles` command. With a stored agency response under `data/` (any server run with an API key stores one within a minute):

```sh
mise exec -- mix gobusgo.basemap.extract \
  --response "raw/oba/agencies-with-coverage/dt=<date>/<name>.json.gz" \
  --snapshot <YYYYMMDD> \
  --output-dir data/basemap \
  --offline-zoom-max 13
```

`--snapshot` is a build date from <https://maps.protomaps.com/builds>, which keeps the past week's builds. The server serves `data/basemap` under `/basemap` with no further step. The full archive is about 189 MB and the zoom-13 offline extract about 34 MB. The basemap is an ODbL produced work, so every page that shows it shows the OpenStreetMap attribution.

## Places and intersections

The places and intersection files are built by hand from [Geofabrik's Washington extract](https://download.geofabrik.de/north-america/us/washington.html) of OpenStreetMap, bounded by the basemap, and refreshed with each basemap refresh. They need `osmium-tool` (`brew install osmium-tool`).

```sh
curl -L --output washington-latest.osm.pbf https://download.geofabrik.de/north-america/us/washington-latest.osm.pbf
curl -L --output washington-latest.osm.pbf.md5 https://download.geofabrik.de/north-america/us/washington-latest.osm.pbf.md5
md5 -q washington-latest.osm.pbf; cat washington-latest.osm.pbf.md5   # the two must match

mix gobusgo.places.build --extract washington-latest.osm.pbf          # about 3 GB of memory
mix gobusgo.intersections.build --extract washington-latest.osm.pbf
```

Both store their files and a manifest under `GOBUSGO_DATA_DIR`. Nothing deletes an earlier build's files, so remove them by hand. Both are derivative databases of OpenStreetMap and are offered under the [Open Database License 1.0](https://opendatacommons.org/licenses/odbl/1-0/), with the license and credit in their manifests. The selection and merge rules are in `lib/gobusgo/places/AGENTS.md` and `lib/gobusgo/intersections/AGENTS.md`; the county address files are in `lib/gobusgo/addresses/AGENTS.md`.

## Vendored front-end assets

The front-end packages (MapLibre GL JS, PMTiles, fflate, the Protomaps basemap styles) and the basemap's fonts and icons are downloaded at versions pinned in `assets/vendor.lock.json`, with a hash for every file, and a download whose hash differs is refused. `mix assets.setup` fetches them.

```sh
mix gobusgo.vendor.update                          # every package to its latest version
mix gobusgo.vendor.update pmtiles --version 4.4.0  # one package to a given version
mix gobusgo.vendor.update basemaps-assets --version <40-digit commit>
```

The lock file's diff is the change to commit. Run `mix assets.build` after an update and check the pages that use the package. A new package needs its license added to the app's credits and to the [README](../README.md#credits-and-licenses).

## Inspecting a running server

Start the server as a named node bound to localhost:

```sh
ERL_EPMD_ADDRESS=127.0.0.1 iex --sname gobusgo \
  --erl "-kernel inet_dist_use_interface {127,0,0,1}" -S mix phx.server
```

Then read from it with a short-lived second node:

```sh
elixir --sname probe --rpc-eval gobusgo@$(hostname -s) \
  'IO.inspect(:ets.info(Gobusgo.OneBusAway.VehicleView, :size))'
```

An expression runs with the server's full power and its API key, so keep it read-only, and ask for sizes and samples rather than whole process states.

## Memory of the vehicle page

```sh
mix test --only memory
```

prints the memory the vehicle page and the vehicle view hold over a synthetic day of fetches. `lib/gobusgo_web/live/AGENTS.md` ("Memory checks") holds the browser-side measurement.
