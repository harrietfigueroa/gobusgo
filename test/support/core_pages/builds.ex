defmodule Gobusgo.Test.CorePages.Builds do
  @moduledoc """
  The two builds of the page's bundles the core page check compares: one
  on the JavaScript core and one on the WebAssembly core, each with the
  service worker built over its own bundle. Both run the esbuild profile
  `mix assets.build` runs, `:default`, written to a directory of their own;
  they differ only in the aliases of the core's specifiers, `#core/<module>.js`,
  which `assets/package.json` maps to `assets/js/core/`.

  The WebAssembly build aliases each module of `webassembly_aliases/0` to
  the file that calls the Rust core in its place. The JavaScript build
  aliases none, and drops any alias of a core specifier the profile itself
  carries, so it stays on the JavaScript core whatever production ships.

  `install/2` copies one build over the bundles and the worker under
  `priv/static`, so the test server serves that build at the paths a page
  loads; the check installs the JavaScript build again when it ends.
  """

  alias Gobusgo.Assert
  alias GobusgoWeb.ServiceWorker

  @type core :: :javascript | :webassembly

  @cores [:javascript, :webassembly]
  @bundles ["app.js", "trip_app.js", "arrivals_board.js"]
  @core_alias_prefix "--alias:#core/"
  @static_dir Path.expand("../../../priv/static", __DIR__)
  @service_worker_name "sw.js"

  # Each module of the core whose callers the WebAssembly build switches,
  # by its specifier, to the module that stands in for it, a path from
  # `assets/`. A port adds its module group here when it switches them.
  @webassembly_aliases %{}

  @doc "The cores, in the order the check runs them."
  @spec cores() :: [core(), ...]
  def cores, do: @cores

  @doc "The aliases of the WebAssembly build, by core specifier."
  @spec webassembly_aliases() :: %{String.t() => String.t()}
  def webassembly_aliases, do: @webassembly_aliases

  @doc """
  Builds both cores under `dir`, each in `<dir>/<core>`, with
  `extra_aliases` added to the build of their core, and returns `dir`.
  """
  @spec build(String.t(), %{core() => %{String.t() => String.t()}}) :: String.t()
  def build(dir, extra_aliases \\ %{}) when is_binary(dir) and is_map(extra_aliases) do
    for core <- @cores do
      aliases = Map.merge(aliases(core), Map.get(extra_aliases, core, %{}))
      build_core(%{dir: Path.join(dir, Atom.to_string(core)), aliases: aliases})
    end

    dir
  end

  @doc "Copies the build of `core` under `dir` over the bundles and the worker the server serves."
  @spec install(String.t(), core()) :: :ok
  def install(dir, core) when is_binary(dir) and core in @cores do
    source_dir = Path.join(dir, Atom.to_string(core))

    for bundle <- @bundles do
      File.cp!(
        Path.join([source_dir, "js", bundle]),
        Path.join([@static_dir, "assets/js", bundle])
      )
    end

    File.cp!(
      Path.join(source_dir, @service_worker_name),
      Path.join(@static_dir, @service_worker_name)
    )
  end

  defp aliases(:javascript), do: %{}
  defp aliases(:webassembly), do: @webassembly_aliases

  defp build_core(%{dir: dir, aliases: aliases}) do
    js_dir = Path.join(dir, "js")
    File.mkdir_p!(js_dir)

    alias_args =
      for {specifier, path} <- Enum.sort(aliases) do
        Assert.condition(
          String.starts_with?(specifier, "#core/"),
          "an alias names a core specifier, got: #{specifier}"
        )

        "--alias:#{specifier}=#{path}"
      end

    profile = Application.fetch_env!(:esbuild, :default)
    profile_args = Enum.reject(profile[:args], &String.starts_with?(&1, @core_alias_prefix))
    profile = Keyword.put(profile, :args, profile_args)
    status = run_esbuild(:core_pages_bundles, profile, ["--outdir=#{js_dir}" | alias_args])
    Assert.condition(status == 0, "the bundles of #{dir} must build, esbuild exited #{status}")
    build_service_worker(dir)
  end

  # The worker of a build is built over that build's script and the
  # stylesheet and map library `mix assets.build` wrote, so its release and
  # stored paths are those of the files the server serves once it is
  # installed.
  defp build_service_worker(dir) do
    paths = ServiceWorker.precache_paths(:undigested)
    files = Enum.map(paths, &{&1, built_file(dir, &1)})
    release = ServiceWorker.release(files)
    build = ServiceWorker.build(%{release: release, precache_paths: paths})
    definition = JSON.encode!(build)
    profile = Application.fetch_env!(:esbuild, :service_worker)
    outfile = Path.join(dir, @service_worker_name)

    status =
      run_esbuild(:core_pages_service_worker, profile, [
        "--define:SERVICE_WORKER_BUILD=#{definition}",
        "--outfile=#{outfile}"
      ])

    Assert.condition(status == 0, "the worker of #{dir} must build, esbuild exited #{status}")
  end

  defp built_file(dir, "/assets/js/" <> bundle), do: File.read!(Path.join([dir, "js", bundle]))
  defp built_file(_dir, "/" <> path), do: File.read!(Path.join(@static_dir, path))

  # esbuild takes the last of a repeated option, so the output given here
  # replaces the profile's own.
  defp run_esbuild(name, profile, extra_args) do
    Application.put_env(:esbuild, name, profile)
    Esbuild.run(name, extra_args ++ ["--log-level=warning"])
  end
end
