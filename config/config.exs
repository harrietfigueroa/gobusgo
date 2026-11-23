import Config

# The options every bundle relies on, written out where esbuild has a
# default for them, so a version of esbuild whose defaults differ builds
# the same bundles. The targets are the oldest browsers the site supports,
# so esbuild lowers only the syntax they lack.
bundle_options =
  ~w(--bundle --platform=browser --charset=utf8 --tree-shaking=true --legal-comments=eof --target=chrome110,firefox115,safari16.4,ios16.4)

config :esbuild,
  version: "0.25.5",
  # The vehicle page's script, an ES module. The metafile names every input
  # and its bytes in the bundle. esbuild substitutes an aliased import path
  # before any other resolution, and resolves the replacement in the
  # working directory, `assets/`, rather than beside the importing file.
  # https://esbuild.github.io/api/#alias — checked 2026-11-23
  default: [
    args:
      ~w(js/app.js --format=esm --outdir=../priv/static/assets/js --metafile=../_build/assets/app.meta.json --alias:fflate=./vendor/fflate/esm/browser.js --alias:#core/routing_snapshot.js=./js/core.js) ++
        bundle_options,
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ],
  # The MCP apps' scripts, which a host's frame of another origin loads as
  # classic scripts, since the files are served with no CORS header a module
  # script from another origin needs.
  mcp_apps: [
    args:
      ~w(js/trip_app.js js/arrivals_board.js --format=iife --outdir=../priv/static/assets/js) ++
        bundle_options,
    cd: Path.expand("../assets", __DIR__)
  ],
  # The service worker is a script of its own at the root, so its scope is
  # the whole site. The profile defines no build: `mix
  # gobusgo.assets.service_worker` runs it with the release and the paths
  # the worker stores.
  service_worker: [
    args: ~w(js/service_worker.js --format=iife --outfile=../priv/static/sw.js) ++ bundle_options,
    cd: Path.expand("../assets", __DIR__)
  ],
  # MapLibre's module files are copied as they are and served beside each
  # other: the library starts its worker from the file next to its own, so
  # it cannot be part of the bundle. The profile names no output directory:
  # `mix gobusgo.assets.map_library` runs it with the one of the library's
  # version.
  vendor: [
    args:
      ~w(vendor/maplibre-gl/dist/maplibre-gl.mjs vendor/maplibre-gl/dist/maplibre-gl-shared.mjs vendor/maplibre-gl/dist/maplibre-gl-worker.mjs --loader:.mjs=copy),
    cd: Path.expand("../assets", __DIR__)
  ]

config :gobusgo, Gobusgo.Deleter, backend: Gobusgo.Deleter.LocalFile

# Records go straight to their subscribers in the running application: a
# "response stored" event to the consumer that processes the stored
# response, and the processed records of a dataset to its view.
config :gobusgo, Gobusgo.Publisher, backend: Gobusgo.Publisher.InProcess

config :gobusgo, Gobusgo.Publisher.InProcess,
  subscribers: %{
    "gbfs.free-bike-status.response-stored" =>
      {Gobusgo.OneBusAway.ResponseConsumer, :consume,
       [
         %{
           event: Gobusgo.Gbfs.RawVehicleStatus.StoredEvent,
           processor: Gobusgo.Gbfs.VehicleStatusBatch
         },
         []
       ]},
    "gbfs.free-bike-status.state" =>
      {Gobusgo.Gbfs.VehicleStatusView, :apply_records, [Gobusgo.Gbfs.VehicleStatusView]},
    "gbfs.vehicle-types.state" =>
      {Gobusgo.OneBusAway.FetchView, :apply_records, [Gobusgo.Gbfs.VehicleTypeView]},
    "oba.agencies-with-coverage.response-stored" =>
      {Gobusgo.OneBusAway.ResponseConsumer, :consume,
       [
         %{
           event: Gobusgo.OneBusAway.RawAgencyResponse.StoredEvent,
           processor: Gobusgo.OneBusAway.AgencyBatch
         },
         []
       ]},
    "oba.vehicles-for-agency.response-stored" =>
      {Gobusgo.OneBusAway.ResponseConsumer, :consume,
       [
         %{
           event: Gobusgo.OneBusAway.RawVehicleResponse.StoredEvent,
           processor: Gobusgo.OneBusAway.VehicleBatch
         },
         []
       ]},
    "oba.routes.response-stored" =>
      {Gobusgo.OneBusAway.ResponseConsumer, :consume,
       [
         %{
           event: Gobusgo.OneBusAway.RouteDatasets,
           processor: Gobusgo.OneBusAway.RouteDatasets
         },
         []
       ]},
    "oba.arrivals.response-stored" =>
      {Gobusgo.OneBusAway.ResponseConsumer, :consume,
       [
         %{
           event: Gobusgo.OneBusAway.RawArrivalResponse.StoredEvent,
           processor: Gobusgo.OneBusAway.ArrivalBatch
         },
         []
       ]},
    "oba.schedules.response-stored" =>
      {Gobusgo.OneBusAway.ResponseConsumer, :consume,
       [
         %{
           event: Gobusgo.OneBusAway.RawRouteScheduleResponse.StoredEvent,
           processor: Gobusgo.OneBusAway.RouteScheduleBatch
         },
         []
       ]},
    "oba.agencies-with-coverage.state" =>
      {Gobusgo.OneBusAway.AgencyView, :apply_records, [Gobusgo.OneBusAway.AgencyView]},
    "oba.vehicles-for-agency.state" =>
      {Gobusgo.OneBusAway.VehicleView, :apply_records, [Gobusgo.OneBusAway.VehicleView]},
    "oba.routes.state" =>
      {Gobusgo.OneBusAway.FetchView, :apply_records_to_each,
       [[Gobusgo.OneBusAway.RouteView, Gobusgo.OneBusAway.RoutePathView]]},
    "oba.stops.state" =>
      {Gobusgo.OneBusAway.StopView, :apply_records, [Gobusgo.OneBusAway.StopView]},
    "oba.arrivals.state" =>
      {Gobusgo.OneBusAway.FetchView, :apply_records, [Gobusgo.OneBusAway.ArrivalView]},
    "oba.schedules.state" =>
      {Gobusgo.OneBusAway.RouteScheduleView, :apply_records,
       [Gobusgo.OneBusAway.RouteScheduleView]},
    "oba.situations.state" =>
      {Gobusgo.OneBusAway.FetchView, :apply_records_to_each,
       [[Gobusgo.OneBusAway.VehicleSituationView, Gobusgo.OneBusAway.ArrivalSituationView]]}
  }

config :gobusgo, Gobusgo.Reader, backend: Gobusgo.Reader.LocalFile
config :gobusgo, Gobusgo.Writer, backend: Gobusgo.Writer.LocalFile

# The first format answers a request that accepts anything.
config :gobusgo, GobusgoWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [json: GobusgoWeb.ErrorJSON, html: GobusgoWeb.ErrorHTML],
    layout: false
  ],
  pubsub_server: Gobusgo.PubSub,
  live_view: [signing_salt: "live_view"]

# The modules the MCP endpoint serves, implementing GobusgoWeb.Mcp.Tool and
# GobusgoWeb.Mcp.Resource.
config :gobusgo, GobusgoWeb.Mcp,
  tools: [
    GobusgoWeb.Mcp.Tools.Alerts,
    GobusgoWeb.Mcp.Tools.Arrivals,
    GobusgoWeb.Mcp.Tools.ArrivalsBoard,
    GobusgoWeb.Mcp.Tools.Find,
    GobusgoWeb.Mcp.Tools.PlanTrip,
    GobusgoWeb.Mcp.Tools.Route,
    GobusgoWeb.Mcp.Tools.Vehicles
  ],
  resources: [
    GobusgoWeb.Mcp.Resources.Agencies,
    GobusgoWeb.Mcp.Resources.ArrivalsBoard,
    GobusgoWeb.Mcp.Resources.RoutingManifest,
    GobusgoWeb.Mcp.Resources.TripApp
  ]

# The sources run on their schedule everywhere except under test, where no
# request may leave the machine.
config :gobusgo, :ingestion, scheduled: config_env() != :test

# MapLibre checks a style against the style specification as it loads it,
# which reports a malformed style or layer and costs time on every load.
# A production build skips the check.
# https://maplibre.org/maplibre-gl-js/docs/API/type-aliases/StyleOptions/ — checked 2026-11-09
config :gobusgo, :map_style, validated: config_env() != :prod

# Page connections are recorded everywhere except under test, where the
# pages the tests mount would be written into the data directory.
config :gobusgo, :usage, recorded: config_env() != :test

# The routing snapshots measure a walk along the walk graph's streets.
# `:straight` measures it by the straight line between two positions, which a
# snapshot also falls back to while no walk graph is published.
config :gobusgo, :walk, basis: :streets

# Phoenix's list with `.mjs` and `.wasm` added, so the digest writes a gzip
# copy of MapLibre's ES module files and of the core's WebAssembly module as it
# does of the bundle.
# deps/phoenix/mix.exs, `gzippable_exts` — checked 2026-11-20
config :phoenix,
       :gzippable_exts,
       ~w(.js .mjs .wasm .map .css .txt .text .html .json .svg .eot .ttf)

config :phoenix, :json_library, JSON

config :tailwind,
  version: "4.3.0",
  default: [
    args: ~w(--input=assets/css/app.css --output=priv/static/assets/css/app.css),
    cd: Path.expand("..", __DIR__)
  ]

# The core page check drives the vehicle page and the MCP apps in Chromium
# and WebKit through the Playwright of the conformance suite,
# `tools/conformance/node_modules/playwright/cli.js`, so both tools run one
# Playwright release. The browser keeps the time zone and the language of
# the region the pages serve.
if config_env() == :test do
  config :phoenix_test,
    otp_app: :gobusgo,
    playwright: [
      assets_dir: "tools/conformance",
      browser_pools: [
        [id: :chromium, browser: :chromium, size: 1],
        [id: :webkit, browser: :webkit, size: 1]
      ],
      browser_launch_timeout: 30_000,
      timeout: 10_000,
      trace_dir: "tmp/core_pages/traces",
      browser_context_opts: [timezone_id: "America/Los_Angeles", locale: "en-US"]
    ]
end

if config_env() == :dev do
  config :gobusgo, GobusgoWeb.Endpoint,
    watchers: [
      esbuild: {Esbuild, :install_and_run, [:default, ~w(--sourcemap=inline --watch)]},
      esbuild_mcp_apps: {Esbuild, :install_and_run, [:mcp_apps, ~w(--sourcemap=inline --watch)]},
      tailwind: {Tailwind, :install_and_run, [:default, ~w(--watch)]}
    ]
end

# With no public host name the socket accepts a page of every origin. A
# production build requires the name, and the endpoint is started with the
# one origin it gives.
if config_env() != :prod do
  config :gobusgo, GobusgoWeb.Endpoint, check_origin: false
end

# A production build is a release, which has no command that starts the
# listener separately. Its assets are the digested ones `mix assets.deploy`
# writes, named in the manifest.
if config_env() == :prod do
  config :gobusgo, GobusgoWeb.Endpoint,
    server: true,
    cache_static_manifest: "priv/static/cache_manifest.json"

  config :logger, level: :info
end
