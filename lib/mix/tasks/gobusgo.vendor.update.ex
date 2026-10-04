defmodule Mix.Tasks.Gobusgo.Vendor.Update do
  @shortdoc "Moves a vendored front-end package or archive to another version"

  @moduledoc """
  Moves vendored front-end assets to another version: downloads the version,
  writes its files, and rewrites `assets/vendor.lock.json`, which is the
  change to commit.

      mix gobusgo.vendor.update
      mix gobusgo.vendor.update PACKAGE
      mix gobusgo.vendor.update PACKAGE --version VERSION
      mix gobusgo.vendor.update PACKAGE --file PATH [--file PATH ...]
      mix gobusgo.vendor.update ARCHIVE --version COMMIT
      mix gobusgo.vendor.update ARCHIVE --version COMMIT --repository OWNER/NAME --directory DIRECTORY [--directory DIRECTORY ...]

    * With no name, every package in the lock file moves to its latest
      version. Archives stay where they are.
    * With a package, that package moves to its latest version, or to
      `--version`, which may be older than the pinned one.
    * `--file` names a path inside the package to take, in place of the
      paths the lock file names. It is how a package is added: a package the
      lock file does not hold needs at least one `--file`.
    * An archive is a GitHub repository pinned by commit. It moves only to
      the commit `--version` names, all 40 hexadecimal digits, older or
      newer than the pinned one.
    * `--repository` and `--directory` name the repository and the
      directories to take. They are how an archive is added, and a name with
      `--repository` is an archive.

  The latest version of a package is the one the registry's `latest` tag
  names. The task does not start the application and exits with a failure
  when an update fails; entries updated before the failure stay updated.
  """

  use Mix.Task

  alias Gobusgo.VendorAssets

  @switches [version: :string, file: :keep, repository: :string, directory: :keep]

  @impl Mix.Task
  def run(arguments) do
    {:ok, _started} = Application.ensure_all_started(:req)
    paths = VendorAssets.paths()
    names = entry_names(paths)

    case OptionParser.parse(arguments, strict: @switches) do
      {[], [], []} ->
        Enum.each(names.packages, &update_package(paths, &1, []))

        for name <- names.archives do
          Mix.shell().info("#{name}: an archive moves only with --version COMMIT")
        end

      {options, [name], []} ->
        if name in names.archives or Keyword.has_key?(options, :repository) do
          update_archive(paths, name, options)
        else
          update_package(paths, name, options)
        end

      {_options, _names, _invalid} ->
        Mix.raise(
          "expected at most one name, with options only beside it; see mix help gobusgo.vendor.update"
        )
    end
  end

  defp entry_names(%{lock_path: lock_path}) do
    case VendorAssets.entry_names(lock_path) do
      {:ok, names} -> names
      {:error, reason} -> Mix.raise("lock file not read: #{inspect(reason)}")
    end
  end

  defp update_package(paths, name, options) do
    for switch <- [:repository, :directory], Keyword.has_key?(options, switch) do
      Mix.raise("--#{switch} belongs to an archive, and #{name} is a package")
    end

    request = %{
      lock_path: paths.lock_path,
      vendor_dir: paths.vendor_dir,
      name: name,
      version: Keyword.get(options, :version, :latest),
      files: values(options, :file)
    }

    report(name, VendorAssets.update(request, []))
  end

  defp update_archive(paths, name, options) do
    if Keyword.has_key?(options, :file) do
      Mix.raise("--file belongs to a package, and #{name} is an archive")
    end

    request = %{
      lock_path: paths.lock_path,
      static_dir: paths.static_dir,
      name: name,
      commit:
        Keyword.get(options, :version) ||
          Mix.raise("#{name} is an archive and moves only with --version COMMIT"),
      repository: Keyword.get(options, :repository),
      directories: values(options, :directory)
    }

    report(name, VendorAssets.update_archive(request, []))
  end

  defp values(options, switch) do
    case Keyword.get_values(options, switch) do
      [] -> nil
      values -> values
    end
  end

  defp report(name, result) do
    case result do
      {:ok, %{version: version, previous_version: version}} ->
        Mix.shell().info("#{name} #{version}: unchanged")

      {:ok, %{version: version, previous_version: nil}} ->
        Mix.shell().info("#{name} #{version}: added")

      {:ok, %{version: version, previous_version: previous_version}} ->
        Mix.shell().info("#{name} #{previous_version} -> #{version}")

      {:error, reason} ->
        Mix.raise("#{name} not updated: #{inspect(reason)}")
    end
  end
end
