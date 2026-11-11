import Config

config :esbuild,
  version: "0.25.5",
  default: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --alias:fflate=./vendor/fflate/esm/browser.js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ],
  # The service worker is a script of its own at the root, so its scope is
  # the whole site. The profile defines no build: `mix
  # gobusgo.assets.service_worker` runs it with the release and the paths
  # the worker stores.
  service_worker: [
    args: ~w(js/service_worker.js --bundle --target=es2022 --outfile=../priv/static/sw.js),
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
    GobusgoWeb.Mcp.Tools.Arrivals,
    GobusgoWeb.Mcp.Tools.Find,
    GobusgoWeb.Mcp.Tools.Vehicles
  ],
  resources: [
    GobusgoWeb.Mcp.Resources.Agencies,
    GobusgoWeb.Mcp.Resources.RoutingManifest
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

# Phoenix's list with `.mjs` added, so the digest writes a gzip copy of
# MapLibre's ES module files as it does of the bundle.
# deps/phoenix/mix.exs, `gzippable_exts` — checked 2026-10-14
config :phoenix, :gzippable_exts, ~w(.js .mjs .map .css .txt .text .html .json .svg .eot .ttf)
config :phoenix, :json_library, JSON

config :tailwind,
  version: "4.3.0",
  default: [
    args: ~w(--input=assets/css/app.css --output=priv/static/assets/css/app.css),
    cd: Path.expand("..", __DIR__)
  ]

if config_env() == :dev do
  config :gobusgo, GobusgoWeb.Endpoint,
    watchers: [
      esbuild: {Esbuild, :install_and_run, [:default, ~w(--sourcemap=inline --watch)]},
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
