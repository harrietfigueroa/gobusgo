defmodule Mix.Tasks.Gobusgo.Assets.MapLibrary do
  @shortdoc "Copies the map library's module files into the built assets"

  @moduledoc """
  Copies the map library's module files, as the vendored package holds
  them, into the directory of the built assets that names the library's
  version, the one `GobusgoWeb.MapLibrary` gives.

      mix gobusgo.assets.map_library

  It runs esbuild's `vendor` profile, which names the files, with that
  directory as its output. `mix assets.build` and `mix assets.deploy` run
  this task. It takes no arguments and does not start the application.
  """

  use Mix.Task

  alias GobusgoWeb.MapLibrary

  # The directory is read from the module compiled from the lock file, so a
  # lock file moved to another version is compiled before the copy is named.
  @requirements ["compile"]

  @esbuild_profile "vendor"
  # Relative to the directory the profile runs in, `assets`.
  @built_dir "../priv/static/assets/vendor"

  @impl Mix.Task
  def run([]) do
    directory = MapLibrary.directory(MapLibrary.version())

    Mix.Task.run("esbuild", [@esbuild_profile, "--outdir=#{@built_dir}/#{directory}"])
  end

  def run(_arguments) do
    Mix.raise("mix gobusgo.assets.map_library takes no arguments")
  end
end
