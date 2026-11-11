import Config

# The writer and the reader share one base directory, so content one stores
# is content the other finds. A release evaluates this file when it starts, so
# a relative directory resolves against the directory the release runs in.
data_dir_default = "data"
data_dir = System.get_env("GOBUSGO_DATA_DIR", data_dir_default)
base_dir = Path.expand(if String.trim(data_dir) == "", do: data_dir_default, else: data_dir)

# With a bucket named, the writer, the reader, and the deleter keep content
# in it. The credentials address is the one the container is given.
s3_bucket = String.trim(System.get_env("GOBUSGO_S3_BUCKET", ""))

# A variable set to nothing reads as one that is not set.
s3_setting = fn name ->
  case String.trim(System.get_env(name, "")) do
    "" -> nil
    value -> value
  end
end

config :gobusgo, Gobusgo.Deleter.LocalFile, base_dir: base_dir
config :gobusgo, Gobusgo.Reader.LocalFile, base_dir: base_dir

config :gobusgo, Gobusgo.S3,
  bucket: s3_bucket,
  prefix: s3_setting.("GOBUSGO_S3_PREFIX") || "",
  region: s3_setting.("GOBUSGO_S3_REGION"),
  endpoint: s3_setting.("GOBUSGO_S3_ENDPOINT"),
  credentials_relative_uri: System.get_env("AWS_CONTAINER_CREDENTIALS_RELATIVE_URI"),
  credentials_full_uri: System.get_env("AWS_CONTAINER_CREDENTIALS_FULL_URI"),
  credentials_authorization: System.get_env("AWS_CONTAINER_AUTHORIZATION_TOKEN")

config :gobusgo, Gobusgo.Writer.LocalFile, base_dir: base_dir

if s3_bucket != "" do
  config :gobusgo, Gobusgo.Deleter, backend: Gobusgo.Deleter.S3
  config :gobusgo, Gobusgo.Reader, backend: Gobusgo.Reader.S3
  config :gobusgo, Gobusgo.Writer, backend: Gobusgo.Writer.S3
end

# The address shard files the local writer stores under `addresses/` are
# served from there.
config :gobusgo, :addresses, dir: Path.join(base_dir, "addresses")

# The basemap archives are served from a directory beside the stored
# responses.
config :gobusgo, :basemap, dir: Path.join(base_dir, "basemap")

# The address the pages link for donations; unset, they link none.
config :gobusgo, :donation, url: System.get_env("GOBUSGO_DONATION_URL")

config :gobusgo, :http,
  host: System.get_env("GOBUSGO_HTTP_HOST"),
  port: System.get_env("GOBUSGO_HTTP_PORT")

# Credentials come from the environment only; nothing here is committed.
config :gobusgo, :one_bus_away,
  base_url: System.get_env("ONEBUSAWAY_BASE_URL"),
  api_key: System.get_env("ONEBUSAWAY_API_KEY")

# The places files the local writer stores under `places/` are served from
# there.
config :gobusgo, :places, dir: Path.join(base_dir, "places")

# The host name pages are served on, which the socket's origin check needs.
config :gobusgo, :public,
  host: System.get_env("GOBUSGO_PUBLIC_HOST"),
  required: config_env() == :prod

# The commit the application was built from, which the image build sets.
config :gobusgo, :revision, revision: System.get_env("GOBUSGO_REVISION")

# The routing snapshot files the local writer stores under `routing/` are
# served from there.
config :gobusgo, :routing, dir: Path.join(base_dir, "routing")

config :gobusgo, :session,
  secret_key_base: System.get_env("SECRET_KEY_BASE"),
  required: config_env() == :prod

# The shared vehicle files the local writer stores under `shared-vehicles/`
# are served from there.
config :gobusgo, :shared_vehicle_tiles, dir: Path.join(base_dir, "shared-vehicles")

# The tile archives the local writer stores under `tiles/` are served from
# there.
config :gobusgo, :tiles, dir: Path.join(base_dir, "tiles")

# When the vehicle page moves its markers continuously; an unset or blank
# variable takes the default `Gobusgo.Config` names.
config :gobusgo, :vehicle_motion,
  zoom_min: System.get_env("GOBUSGO_VEHICLE_MOTION_ZOOM_MIN"),
  zoom_max: System.get_env("GOBUSGO_VEHICLE_MOTION_ZOOM_MAX"),
  hysteresis: System.get_env("GOBUSGO_VEHICLE_MOTION_HYSTERESIS"),
  vehicle_count_max: System.get_env("GOBUSGO_VEHICLE_MOTION_VEHICLE_COUNT_MAX"),
  rates: System.get_env("GOBUSGO_VEHICLE_MOTION_RATES")
