import Config

# The writer and the reader share one base directory, so content one stores
# is content the other finds. A release evaluates this file when it starts, so
# a relative directory resolves against the directory the release runs in.
data_dir_default = "data"
data_dir = System.get_env("GOBUSGO_DATA_DIR", data_dir_default)
base_dir = Path.expand(if String.trim(data_dir) == "", do: data_dir_default, else: data_dir)

config :gobusgo, Gobusgo.Reader.LocalFile, base_dir: base_dir
config :gobusgo, Gobusgo.Writer.LocalFile, base_dir: base_dir

# The basemap archives are served from a directory beside the stored
# responses.
config :gobusgo, :basemap, dir: Path.join(base_dir, "basemap")

config :gobusgo, :http,
  host: System.get_env("GOBUSGO_HTTP_HOST"),
  port: System.get_env("GOBUSGO_HTTP_PORT")

# Credentials come from the environment only; nothing here is committed.
config :gobusgo, :one_bus_away,
  base_url: System.get_env("ONEBUSAWAY_BASE_URL"),
  api_key: System.get_env("ONEBUSAWAY_API_KEY")

config :gobusgo, :session,
  secret_key_base: System.get_env("SECRET_KEY_BASE"),
  required: config_env() == :prod
