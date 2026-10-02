import Config

# The base directory is expanded once, when configuration loads.
config :gobusgo, Gobusgo.Writer, backend: Gobusgo.Writer.LocalFile

config :gobusgo, Gobusgo.Writer.LocalFile, base_dir: Path.expand("data")
