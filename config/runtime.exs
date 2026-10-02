import Config

# Credentials come from the environment only; nothing here is committed.
config :gobusgo, :one_bus_away,
  base_url: System.get_env("ONEBUSAWAY_BASE_URL"),
  api_key: System.get_env("ONEBUSAWAY_API_KEY")

config :gobusgo, :http,
  host: System.get_env("GOBUSGO_HTTP_HOST"),
  port: System.get_env("GOBUSGO_HTTP_PORT")
