defmodule Gobusgo.Test.CorePages.Builds do
  @moduledoc """
  The two builds of the page's bundles the core page check compares: one
  on the JavaScript core and one on the WebAssembly core, each with the
  service worker built over its own bundle. Both run the esbuild profiles
  of the bundles `mix assets.build` runs, `:default` and `:mcp_apps`,
  written to a directory of their own, the vehicle page's metafile with them;
  they differ only in the aliases of the core's specifiers, `#core/<module>.js`,
  which `assets/package.json` maps to `assets/js/core/`.

  The WebAssembly build aliases each module of `webassembly_aliases/0` to
  the file that calls the Rust core in its place. The JavaScript build
  aliases none, and drops any alias of a core specifier the profile itself
  carries, so it stays on the JavaScript core whatever production ships.

  `install/2` copies one build over the bundles and the worker under
  `priv/static`, so the test server serves that build at the paths a page
  loads. `preserve/1` keeps a copy of the bundles and the worker found
  there, and `restore/1` puts them back; a copy whose marker remains is
  that of a run that never restored, and is put back before a new copy is
  taken.
  """

  alias Gobusgo.Assert
  alias GobusgoWeb.ServiceWorker

  @type core :: :javascript | :webassembly

  @cores [:javascript, :webassembly]
  @core_alias_prefix "--alias:#core/"
  @metafile_prefix "--metafile="
  # The esbuild profiles of the bundles `mix assets.build` runs.
  @bundle_profiles [:default, :mcp_apps]
  # Their entry points, the bundles a build writes and installs.
  @bundles for profile <- @bundle_profiles,
               arg <- Application.compile_env!(:esbuild, [profile, :args]),
               not String.starts_with?(arg, "-"),
               do: Path.basename(arg)
  # Plug.Static answers a request with a compressed copy beside the file,
  # so a copy left by `mix assets.deploy` would be served for every build.
  @compressed_extensions [".gz", ".br"]
  @preserved_marker "preserved"
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

  @doc """
  Copies the build of `core` under `dir` over the bundles and the worker the
  server serves. Raises where a compressed copy stands beside one of them.
  """
  @spec install(String.t(), core()) :: :ok
  def install(dir, core) when is_binary(dir) and core in @cores do
    copy_into_static(Path.join(dir, Atom.to_string(core)))
  end

  @doc """
  Copies the bundles and the worker the server serves into `dir` and marks
  the copy, after restoring a marked copy an earlier run left there.
  """
  @spec preserve(String.t()) :: :ok
  def preserve(dir) when is_binary(dir) do
    marker = Path.join(dir, @preserved_marker)

    if File.exists?(marker) do
      :ok = restore(dir)
    end

    File.mkdir_p!(Path.join(dir, "js"))

    for {build_path, static_path} <- served_paths() do
      File.cp!(Path.join(@static_dir, static_path), Path.join(dir, build_path))
    end

    File.write!(marker, "")
  end

  @doc "Copies the bundles and the worker `preserve/1` kept in `dir` back, and drops its marker."
  @spec restore(String.t()) :: :ok
  def restore(dir) when is_binary(dir) do
    marker = Path.join(dir, @preserved_marker)
    Assert.condition(File.exists?(marker), "#{dir} must hold a preserved copy to restore")
    :ok = copy_into_static(dir)
    File.rm!(marker)
  end

  # Each file a build holds, by its path in the build's directory and in
  # `priv/static`.
  defp served_paths do
    [{@service_worker_name, @service_worker_name}] ++
      for bundle <- @bundles, do: {Path.join("js", bundle), Path.join("assets/js", bundle)}
  end

  defp copy_into_static(dir) do
    for {build_path, static_path} <- served_paths() do
      target = Path.join(@static_dir, static_path)
      :ok = refute_compressed(target)
      File.cp!(Path.join(dir, build_path), target)
    end

    :ok
  end

  defp refute_compressed(path) do
    for extension <- @compressed_extensions do
      compressed = path <> extension

      Assert.condition(
        not File.exists?(compressed),
        "#{compressed} would be served in place of every build's #{Path.basename(path)}; " <>
          "delete it, since `mix assets.deploy` writes it and `mix assets.build` does not"
      )
    end

    :ok
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

    for name <- @bundle_profiles do
      build_profile(%{name: name, dir: dir, js_dir: js_dir, alias_args: alias_args})
    end

    built = js_dir |> File.ls!() |> Enum.sort()

    Assert.condition(
      built == Enum.sort(@bundles),
      "the build of #{dir} must hold the bundles #{inspect(@bundles)}, got: #{inspect(built)}"
    )

    build_service_worker(dir)
  end

  # A profile's own core aliases are dropped, and its metafile is written in
  # the build's directory, so a build leaves the one `mix assets.build`
  # wrote as it was.
  defp build_profile(%{name: name, dir: dir, js_dir: js_dir, alias_args: alias_args}) do
    profile = Application.fetch_env!(:esbuild, name)

    profile_args =
      for arg <- profile[:args], not String.starts_with?(arg, @core_alias_prefix) do
        metafile_in(arg, dir)
      end

    profile = Keyword.put(profile, :args, profile_args)
    status = run_esbuild(:core_pages_bundles, profile, ["--outdir=#{js_dir}" | alias_args])

    Assert.condition(
      status == 0,
      "the #{name} bundles of #{dir} must build, esbuild exited #{status}"
    )
  end

  defp metafile_in(@metafile_prefix <> path, dir),
    do: @metafile_prefix <> Path.join(dir, Path.basename(path))

  defp metafile_in(arg, _dir), do: arg

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
