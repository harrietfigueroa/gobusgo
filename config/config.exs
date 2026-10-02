import Config

# The base directory is expanded once, when configuration loads. The writer
# and the reader share it, so content one stores is content the other finds.
base_dir = Path.expand("data")

config :gobusgo, Gobusgo.Writer, backend: Gobusgo.Writer.LocalFile

config :gobusgo, Gobusgo.Writer.LocalFile, base_dir: base_dir

config :gobusgo, Gobusgo.Reader, backend: Gobusgo.Reader.LocalFile

config :gobusgo, Gobusgo.Reader.LocalFile, base_dir: base_dir

# Records go straight to the views of the running application.
config :gobusgo, Gobusgo.Publisher, backend: Gobusgo.Publisher.InProcess

config :gobusgo, Gobusgo.Publisher.InProcess,
  subscribers: %{
    "oba.agencies-with-coverage.state" =>
      {Gobusgo.OneBusAway.AgencyView, :apply_records, [Gobusgo.OneBusAway.AgencyView]}
  }

config :phoenix, :json_library, JSON

config :gobusgo, GobusgoWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: GobusgoWeb.ErrorJSON], layout: false]
