defmodule Mix.Tasks.Gobusgo.Assets.ServiceWorker do
  @shortdoc "Builds the service worker for the built assets"

  @moduledoc """
  Builds the service worker, `priv/static/sw.js`, for the assets already
  built: it reads the files the worker stores when it installs, takes the
  release from their content with `GobusgoWeb.ServiceWorker`, and runs
  esbuild's `service_worker` profile with the release and the paths defined
  as `SERVICE_WORKER_BUILD`.

      mix gobusgo.assets.service_worker
      mix gobusgo.assets.service_worker --digested

  With `--digested` the paths are the digested names that
  `priv/static/cache_manifest.json` gives, so the task runs after
  `mix phx.digest`; without it they are the names the build wrote. `mix
  assets.build` runs it without the option and `mix assets.deploy` with it.
  It does not start the application.
  """

  use Mix.Task

  alias GobusgoWeb.ServiceWorker

  @esbuild_profile "service_worker"
  @static_dir "priv/static"
  @cache_manifest_path "priv/static/cache_manifest.json"

  @impl Mix.Task
  def run(arguments) do
    digests = digests(arguments)
    paths = ServiceWorker.precache_paths(digests)
    files = Enum.map(paths, &{&1, read_built!(&1)})
    release = ServiceWorker.release(files)
    build = ServiceWorker.build(%{release: release, precache_paths: paths})
    definition = JSON.encode!(build)

    Mix.Task.run("esbuild", [@esbuild_profile, "--define:SERVICE_WORKER_BUILD=#{definition}"])
    Mix.shell().info("Service worker built for release #{release}")
  end

  defp digests([]), do: :undigested

  defp digests(["--digested"]) do
    case File.read(@cache_manifest_path) do
      {:ok, content} -> {:digested, content |> JSON.decode!() |> Map.fetch!("latest")}
      {:error, reason} -> Mix.raise("#{@cache_manifest_path} not readable: #{inspect(reason)}")
    end
  end

  defp digests(_arguments) do
    Mix.raise("mix gobusgo.assets.service_worker takes no arguments or --digested")
  end

  defp read_built!("/" <> path) do
    case File.read(Path.join(@static_dir, path)) do
      {:ok, content} -> content
      {:error, reason} -> Mix.raise("built asset #{path} not readable: #{inspect(reason)}")
    end
  end
end
