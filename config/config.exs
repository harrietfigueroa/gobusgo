import Config

config :esbuild,
  version: "0.25.5",
  default: [
    args: ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => Path.expand("../deps", __DIR__)}
  ]

# Records go straight to their subscribers in the running application: a
# "response stored" event to the consumer that processes the stored response,
# and the processed records of a dataset to its view.
config :gobusgo, Gobusgo.Publisher, backend: Gobusgo.Publisher.InProcess

config :gobusgo, Gobusgo.Publisher.InProcess,
  subscribers: %{
    "oba.agencies-with-coverage.response-stored" =>
      {Gobusgo.OneBusAway.AgencyBatch.Consumer, :consume, [[]]},
    "oba.agencies-with-coverage.state" =>
      {Gobusgo.OneBusAway.AgencyView, :apply_records, [Gobusgo.OneBusAway.AgencyView]},
    "oba.vehicles-for-agency.state" =>
      {Gobusgo.OneBusAway.VehicleView, :apply_records, [Gobusgo.OneBusAway.VehicleView]}
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

# The sources run on their schedule everywhere except under test, where no
# request may leave the machine.
config :gobusgo, :ingestion, scheduled: config_env() != :test

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

# The socket checks a page's origin against the public host name, which
# only a production deployment has.
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
