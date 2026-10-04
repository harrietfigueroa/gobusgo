defmodule Gobusgo.VendorAssets do
  @lock_path "assets/vendor.lock.json"
  @vendor_dir "assets/vendor"

  @moduledoc """
  The vendored front-end packages: files taken out of npm packages at the
  versions a lock file pins, written under a directory git ignores.

  `fetch/2` makes the directory hold what the lock pins. `update/2` moves one
  package to another version and rewrites the lock. Both take the lock's
  path and the directory; `paths/0` names the ones the application uses,
  `#{@lock_path}` and `#{@vendor_dir}`, relative to the project. A file of a
  package is written at `<directory>/<package name>/<path inside the package>`.

  A tarball is used only when it hashes to the integrity it is expected to
  have: the lock's for `fetch/2`, the registry's for `update/2`. `fetch/2`
  also checks each file against the lock, and downloads nothing for a
  package whose files are all present with the pinned content.

  ## Errors

    * `{:lock, reason}`: the lock file is unreadable or breaks a rule of
      `Gobusgo.VendorAssets.Lock`
    * `{:invalid_name, name}`, `{:invalid_version, version}`,
      `{:invalid_file, path}`: a value of the request is malformed
    * `{:unknown_package, name}`: the lock has no such package and the
      request names no files for it
    * `{:registry, name, reason}`: a `Gobusgo.VendorAssets.Registry` error
    * `{:integrity_mismatch, name}`: the tarball does not hash to the
      expected integrity
    * `{:tarball, name, reason}`: the tarball is not an archive, or lacks a
      file
    * `{:file_mismatch, name, path}`: a file does not hash to the lock's
      hash
    * `{:write, reason}`: a file or the lock was not written

  Options go to `Gobusgo.VendorAssets.Registry`.
  """

  alias Gobusgo.VendorAssets.Lock
  alias Gobusgo.VendorAssets.Registry
  alias Gobusgo.VendorAssets.Tarball

  @partial_suffix ".partial"

  @type paths :: %{lock_path: String.t(), vendor_dir: String.t()}
  @type fetched :: %{name: String.t(), version: String.t(), status: :present | :downloaded}
  @type updated :: %{name: String.t(), version: String.t(), previous_version: String.t() | nil}

  @doc "The lock file and the directory the application uses, relative to the project."
  @spec paths() :: paths()
  def paths, do: %{lock_path: @lock_path, vendor_dir: @vendor_dir}

  @doc "Returns the names of the packages in the lock, in name order."
  @spec package_names(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def package_names(lock_path) when is_binary(lock_path) do
    with {:ok, %{packages: packages}} <- read_lock(lock_path) do
      {:ok, Enum.map(packages, & &1.name)}
    end
  end

  @doc """
  Makes the directory hold every file the lock pins, downloading the
  packages whose files are absent or differ. Stops at the first package that
  fails.
  """
  @spec fetch(paths(), keyword()) :: {:ok, [fetched()]} | {:error, term()}
  def fetch(%{lock_path: lock_path, vendor_dir: vendor_dir}, options)
      when is_binary(lock_path) and is_binary(vendor_dir) and is_list(options) do
    with {:ok, %{packages: packages}} <- read_lock(lock_path) do
      # The lock bounds its packages, so the loop is bounded by it.
      fetched =
        Enum.reduce_while(packages, [], fn package, fetched ->
          case fetch_package(package, vendor_dir, options) do
            {:ok, status} ->
              {:cont, [Map.put(Map.take(package, [:name, :version]), :status, status) | fetched]}

            {:error, reason} ->
              {:halt, {:error, reason}}
          end
        end)

      case fetched do
        {:error, reason} -> {:error, reason}
        fetched -> {:ok, Enum.reverse(fetched)}
      end
    end
  end

  @doc """
  Moves the package `request.name` to `request.version`, a version number or
  `:latest`: downloads that version, writes its files, and rewrites the
  lock. `request.files` names the paths to take out of the package, or is
  `nil` to keep the paths the lock already names; with paths, a package the
  lock does not hold is added. The lock is rewritten last, so a failure
  leaves it as it was.
  """
  @spec update(
          %{
            lock_path: String.t(),
            vendor_dir: String.t(),
            name: String.t(),
            version: String.t() | :latest,
            files: [String.t(), ...] | nil
          },
          keyword()
        ) :: {:ok, updated()} | {:error, term()}
  def update(
        %{
          lock_path: lock_path,
          vendor_dir: vendor_dir,
          name: name,
          version: version,
          files: files
        },
        options
      )
      when is_binary(lock_path) and is_binary(vendor_dir) and is_list(options) do
    with :ok <- check_request(name, version, files),
         {:ok, lock} <- read_lock(lock_path),
         {:ok, paths, previous_version} <- package_paths(lock, name, files),
         {:ok, pinned} <-
           registry(name, Registry.fetch_version(%{name: name, version: version}, options)),
         {:ok, contents} <-
           download(
             %{name: name, tarball: pinned.tarball, integrity: pinned.integrity},
             paths,
             options
           ),
         package = Map.merge(pinned, %{name: name, files: file_hashes(contents)}),
         :ok <- write_package(package, contents, vendor_dir),
         :ok <- write_file(lock_path, Lock.encode(Lock.put_package(lock, package))) do
      {:ok, %{name: name, version: pinned.version, previous_version: previous_version}}
    end
  end

  defp check_request(name, version, files) do
    cond do
      not Lock.valid_name?(name) ->
        {:error, {:invalid_name, name}}

      version != :latest and not Lock.valid_version?(version) ->
        {:error, {:invalid_version, version}}

      is_list(files) ->
        check_files(files)

      true ->
        :ok
    end
  end

  defp check_files(files) do
    case Enum.find(files, &(not Lock.valid_path?(&1))) do
      nil -> :ok
      path -> {:error, {:invalid_file, path}}
    end
  end

  defp package_paths(lock, name, files) do
    case {Lock.fetch_package(lock, name), files} do
      {{:ok, package}, nil} -> {:ok, Enum.map(package.files, & &1.path), package.version}
      {{:ok, package}, files} -> {:ok, Enum.uniq(files), package.version}
      {:error, nil} -> {:error, {:unknown_package, name}}
      {:error, files} -> {:ok, Enum.uniq(files), nil}
    end
  end

  defp fetch_package(%{name: name, files: files} = package, vendor_dir, options) do
    if Enum.all?(files, &present?(&1, name, vendor_dir)) do
      {:ok, :present}
    else
      with {:ok, contents} <- download(package, Enum.map(files, & &1.path), options),
           :ok <- check_hashes(package, contents),
           :ok <- write_package(package, contents, vendor_dir) do
        {:ok, :downloaded}
      end
    end
  end

  defp present?(%{path: path, sha256: sha256}, name, vendor_dir) do
    case File.read(target_path(vendor_dir, name, path)) do
      {:ok, content} -> Tarball.sha256(content) == sha256
      {:error, _reason} -> false
    end
  end

  defp download(%{name: name, tarball: url, integrity: integrity}, paths, options) do
    with {:ok, tarball} <- registry(name, Registry.fetch_tarball(url, options)),
         :ok <- check_integrity(name, tarball, integrity) do
      case Tarball.extract(tarball, paths) do
        {:ok, contents} -> {:ok, contents}
        {:error, reason} -> {:error, {:tarball, name, reason}}
      end
    end
  end

  defp registry(_name, {:ok, value}), do: {:ok, value}
  defp registry(name, {:error, reason}), do: {:error, {:registry, name, reason}}

  defp check_integrity(name, tarball, integrity) do
    if Tarball.integrity(tarball) == integrity do
      :ok
    else
      {:error, {:integrity_mismatch, name}}
    end
  end

  defp check_hashes(%{name: name, files: files}, contents) do
    case Enum.find(files, &(Tarball.sha256(Map.fetch!(contents, &1.path)) != &1.sha256)) do
      nil -> :ok
      %{path: path} -> {:error, {:file_mismatch, name, path}}
    end
  end

  defp file_hashes(contents) do
    contents
    |> Enum.map(fn {path, content} -> %{path: path, sha256: Tarball.sha256(content)} end)
    |> Enum.sort_by(& &1.path)
  end

  # The package's directory is removed first, so a file that an earlier
  # version supplied and this one does not is gone.
  defp write_package(%{name: name}, contents, vendor_dir) do
    with {:ok, _removed} <- remove_directory(Path.join(vendor_dir, name)) do
      Enum.reduce_while(contents, :ok, fn {path, content}, :ok ->
        case write_file(target_path(vendor_dir, name, path), content) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp remove_directory(directory) do
    case File.rm_rf(directory) do
      {:ok, removed} -> {:ok, removed}
      {:error, reason, _path} -> {:error, {:write, reason}}
    end
  end

  # Written beside its name and renamed, so a file under its name is whole.
  defp write_file(path, content) do
    partial_path = path <> @partial_suffix

    with :ok <- File.mkdir_p(Path.dirname(path)),
         :ok <- File.write(partial_path, content),
         :ok <- File.rename(partial_path, path) do
      :ok
    else
      {:error, reason} -> {:error, {:write, reason}}
    end
  end

  defp target_path(vendor_dir, name, path), do: Path.join([vendor_dir, name, path])

  # A project without a lock file has no package yet.
  defp read_lock(lock_path) do
    case File.read(lock_path) do
      {:ok, content} ->
        case Lock.decode(content) do
          {:ok, lock} -> {:ok, lock}
          {:error, reason} -> {:error, {:lock, reason}}
        end

      {:error, :enoent} ->
        {:ok, Lock.empty()}

      {:error, reason} ->
        {:error, {:lock, reason}}
    end
  end
end
