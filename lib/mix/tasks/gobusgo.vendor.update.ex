defmodule Mix.Tasks.Gobusgo.Vendor.Update do
  @shortdoc "Moves a vendored front-end package to another version"

  @moduledoc """
  Moves vendored front-end packages to another version: downloads the
  version, writes its files into `assets/vendor`, and rewrites
  `assets/vendor.lock.json`, which is the change to commit.

      mix gobusgo.vendor.update
      mix gobusgo.vendor.update PACKAGE
      mix gobusgo.vendor.update PACKAGE --version VERSION
      mix gobusgo.vendor.update PACKAGE --file PATH [--file PATH ...]

    * With no package, every package in the lock file moves to its latest
      version.
    * With a package, that package moves to its latest version, or to
      `--version`, which may be older than the pinned one.
    * `--file` names a path inside the package to take, in place of the
      paths the lock file names. It is how a package is added: a package the
      lock file does not hold needs at least one `--file`.

  The latest version is the one the registry's `latest` tag names. The task
  does not start the application and exits with a failure when an update
  fails; packages updated before the failure stay updated.
  """

  use Mix.Task

  alias Gobusgo.VendorAssets

  @switches [version: :string, file: :keep]

  @impl Mix.Task
  def run(arguments) do
    {:ok, _started} = Application.ensure_all_started(:req)
    paths = VendorAssets.paths()

    case OptionParser.parse(arguments, strict: @switches) do
      {[], [], []} ->
        Enum.each(package_names(paths), &update(paths, %{name: &1, version: :latest, files: nil}))

      {options, [name], []} ->
        update(paths, %{
          name: name,
          version: Keyword.get(options, :version, :latest),
          files: files(Keyword.get_values(options, :file))
        })

      {_options, _names, _invalid} ->
        Mix.raise(
          "expected at most one package, with --version and --file only beside it; see mix help gobusgo.vendor.update"
        )
    end
  end

  defp files([]), do: nil
  defp files(files), do: files

  defp package_names(%{lock_path: lock_path}) do
    case VendorAssets.package_names(lock_path) do
      {:ok, names} -> names
      {:error, reason} -> Mix.raise("lock file not read: #{inspect(reason)}")
    end
  end

  defp update(paths, package) do
    case VendorAssets.update(Map.merge(paths, package), []) do
      {:ok, %{name: name, version: version, previous_version: version}} ->
        Mix.shell().info("#{name} #{version}: unchanged")

      {:ok, %{name: name, version: version, previous_version: nil}} ->
        Mix.shell().info("#{name} #{version}: added")

      {:ok, %{name: name, version: version, previous_version: previous_version}} ->
        Mix.shell().info("#{name} #{previous_version} -> #{version}")

      {:error, reason} ->
        Mix.raise("#{package.name} not updated: #{inspect(reason)}")
    end
  end
end
