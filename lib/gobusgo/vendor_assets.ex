defmodule Gobusgo.VendorAssets do
  @lock_path "assets/vendor.lock.json"
  @static_dir "priv/vendor"
  @vendor_dir "assets/vendor"

  @moduledoc """
  The vendored front-end assets: files taken from other projects at the
  versions a lock file pins, written under directories git ignores.

  The lock holds two kinds of entry:

    * a package is an npm package, pinned by version. Its files are inputs
      of the asset build, written at
      `<vendor directory>/<package name>/<path inside the package>`
    * an archive is a GitHub repository, pinned by commit. Its directories
      are served as they are, written at
      `<static directory>/<archive name>/<path inside the repository>`

  `fetch/2` makes the directories hold what the lock pins. `update/2` moves
  one entry to another version and rewrites the lock. Both take the lock's
  path and the two directories; `paths/0` names the ones the application
  uses, `#{@lock_path}`, `#{@vendor_dir}`, and `#{@static_dir}`, relative to
  the project.

  Downloaded content is used only when it hashes to what is expected. A
  package's tarball has to hash to the lock's integrity for `fetch/2` and to
  the registry's for `update/2`, and `fetch/2` checks each file against the
  lock as well. An archive's files have to hash to the lock's content hash
  for `fetch/2`; `update/2` records the hash of what the commit holds, and
  the commit is itself a hash of the repository's content. `fetch/2`
  downloads nothing for an entry whose files are all present with the pinned
  content.

  ## Errors

    * `{:lock, reason}`: the lock file is unreadable or breaks a rule of
      `Gobusgo.VendorAssets.Lock`
    * `{:invalid_name, name}`, `{:invalid_version, version}`,
      `{:invalid_file, path}`, `{:invalid_repository, repository}`,
      `{:invalid_commit, commit}`, `{:invalid_directory, directory}`: a
      value of the request is malformed
    * `{:unknown_package, name}`: the lock has no such entry and the request
      names no files or repository for it
    * `{:commit_required, name}`: an archive moves only to a commit the
      request names
    * `{:name_taken, name}`: the name belongs to an entry of the other kind
    * `{:registry, name, reason}`: a `Gobusgo.VendorAssets.Registry` error
    * `{:github, name, reason}`: a `Gobusgo.VendorAssets.Github` error
    * `{:integrity_mismatch, name}`: the tarball does not hash to the
      expected integrity
    * `{:tarball, name, reason}`: the tarball or the archive is not an
      archive, or lacks a file or a directory
    * `{:file_mismatch, name, path}`: a file does not hash to the lock's
      hash
    * `{:content_mismatch, name}`: an archive's files do not hash to the
      lock's content hash
    * `{:write, reason}`: a file or the lock was not written

  Options go to the request modules.
  """

  alias Gobusgo.VendorAssets.Github
  alias Gobusgo.VendorAssets.Lock
  alias Gobusgo.VendorAssets.Registry
  alias Gobusgo.VendorAssets.Tarball

  @partial_suffix ".partial"

  @file_count_max 4_096

  @type paths :: %{lock_path: String.t(), vendor_dir: String.t(), static_dir: String.t()}
  @type fetched :: %{name: String.t(), version: String.t(), status: :present | :downloaded}
  @type updated :: %{name: String.t(), version: String.t(), previous_version: String.t() | nil}

  @doc "The lock file and the directory the application uses, relative to the project."
  @spec paths() :: paths()
  def paths, do: %{lock_path: @lock_path, vendor_dir: @vendor_dir, static_dir: @static_dir}

  @doc "Returns the names of the packages and of the archives in the lock, each in name order."
  @spec entry_names(String.t()) ::
          {:ok, %{packages: [String.t()], archives: [String.t()]}} | {:error, term()}
  def entry_names(lock_path) when is_binary(lock_path) do
    with {:ok, %{packages: packages, archives: archives}} <- read_lock(lock_path) do
      {:ok, %{packages: Enum.map(packages, & &1.name), archives: Enum.map(archives, & &1.name)}}
    end
  end

  @doc """
  Makes the directories hold every file the lock pins, downloading the
  entries whose files are absent or differ: the packages, then the
  archives, whose `version` in the result is the commit. Stops at the first
  entry that fails.
  """
  @spec fetch(paths(), keyword()) :: {:ok, [fetched()]} | {:error, term()}
  def fetch(%{lock_path: lock_path, vendor_dir: vendor_dir, static_dir: static_dir}, options)
      when is_binary(lock_path) and is_binary(vendor_dir) and is_binary(static_dir) and
             is_list(options) do
    with {:ok, %{packages: packages, archives: archives}} <- read_lock(lock_path) do
      entries =
        Enum.map(
          packages,
          &{&1.name, &1.version, fn -> fetch_package(&1, vendor_dir, options) end}
        ) ++
          Enum.map(
            archives,
            &{&1.name, &1.commit, fn -> fetch_archive(&1, static_dir, options) end}
          )

      # The lock bounds its entries, so the loop is bounded by it.
      fetched =
        Enum.reduce_while(entries, [], fn {name, version, fetch}, fetched ->
          case fetch.() do
            {:ok, status} -> {:cont, [%{name: name, version: version, status: status} | fetched]}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)

      case fetched do
        {:error, reason} -> {:error, reason}
        fetched -> {:ok, Enum.reverse(fetched)}
      end
    end
  end

  @doc """
  Moves the archive `request.name` to `request.commit`: downloads the
  repository at that commit, writes the files of its directories, and
  rewrites the lock. `request.repository` and `request.directories` name the
  repository and the directories to take, or are `nil` to keep what the lock
  already names; with both, an archive the lock does not hold is added. The
  lock is rewritten last, so a failure leaves it as it was.
  """
  @spec update_archive(
          %{
            lock_path: String.t(),
            static_dir: String.t(),
            name: String.t(),
            commit: String.t(),
            repository: String.t() | nil,
            directories: [String.t(), ...] | nil
          },
          keyword()
        ) :: {:ok, updated()} | {:error, term()}
  def update_archive(
        %{lock_path: lock_path, static_dir: static_dir, name: name, commit: commit} = request,
        options
      )
      when is_binary(lock_path) and is_binary(static_dir) and is_list(options) do
    with {:ok, lock} <- read_lock(lock_path),
         {:ok, source, previous_commit} <- archive_source(lock, request),
         pinned =
           Map.merge(source, %{name: name, commit: commit, content_sha256: nil, file_count: nil}),
         {:ok, contents} <- download_archive(pinned, options),
         archive = %{
           pinned
           | content_sha256: Tarball.content_sha256(contents),
             file_count: map_size(contents)
         },
         :ok <- write_entry(Path.join(static_dir, name), contents),
         :ok <- write_file(lock_path, Lock.encode(Lock.put_archive(lock, archive))) do
      {:ok, %{name: name, version: commit, previous_version: previous_commit}}
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
         :error <- Lock.fetch_archive(lock, name),
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
    else
      {:ok, %{commit: _commit}} -> {:error, {:name_taken, name}}
      {:error, reason} -> {:error, reason}
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

  defp write_package(%{name: name}, contents, vendor_dir) do
    write_entry(Path.join(vendor_dir, name), contents)
  end

  # The entry's directory is removed first, so a file that an earlier
  # version supplied and this one does not is gone.
  defp write_entry(directory, contents) do
    with {:ok, _removed} <- remove_directory(directory) do
      Enum.reduce_while(contents, :ok, fn {path, content}, :ok ->
        case write_file(Path.join(directory, path), content) do
          :ok -> {:cont, :ok}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp archive_source(lock, %{
         name: name,
         commit: commit,
         repository: repository,
         directories: directories
       }) do
    existing = Lock.fetch_archive(lock, name)

    source =
      case existing do
        {:ok, archive} ->
          %{
            repository: repository || archive.repository,
            directories: directories || archive.directories
          }

        :error ->
          %{repository: repository, directories: directories}
      end

    cond do
      Lock.fetch_package(lock, name) != :error ->
        {:error, {:name_taken, name}}

      is_nil(source.repository) or is_nil(source.directories) ->
        {:error, {:unknown_package, name}}

      not Lock.valid_commit?(commit) ->
        {:error, {:invalid_commit, commit}}

      true ->
        check_archive_source(name, commit, source, existing)
    end
  end

  defp check_archive_source(name, commit, source, existing) do
    candidate =
      Map.merge(source, %{
        name: name,
        commit: commit,
        directories: source.directories |> Enum.uniq() |> Enum.sort(),
        content_sha256: String.duplicate("0", 64),
        file_count: 1
      })

    previous_commit =
      case existing do
        {:ok, archive} -> archive.commit
        :error -> nil
      end

    case Lock.invalid_archive_field(candidate) do
      nil ->
        {:ok, Map.take(candidate, [:repository, :directories]), previous_commit}

      :name ->
        {:error, {:invalid_name, name}}

      :repository ->
        {:error, {:invalid_repository, source.repository}}

      :directories ->
        {:error, {:invalid_directory, Enum.find(source.directories, &(not Lock.valid_path?(&1)))}}
    end
  end

  defp fetch_archive(%{name: name} = archive, static_dir, options) do
    directory = Path.join(static_dir, name)

    if stored_content_sha256(directory) == archive.content_sha256 do
      {:ok, :present}
    else
      with {:ok, contents} <- download_archive(archive, options),
           :ok <- check_content(archive, contents),
           :ok <- write_entry(directory, contents) do
        {:ok, :downloaded}
      end
    end
  end

  defp download_archive(
         %{name: name, repository: repository, commit: commit, directories: directories},
         options
       ) do
    case Github.fetch_archive(%{repository: repository, commit: commit}, options) do
      {:ok, tarball} ->
        case Tarball.extract_directories(tarball, directories) do
          {:ok, contents} -> {:ok, contents}
          {:error, reason} -> {:error, {:tarball, name, reason}}
        end

      {:error, reason} ->
        {:error, {:github, name, reason}}
    end
  end

  defp check_content(%{name: name, content_sha256: content_sha256}, contents) do
    if Tarball.content_sha256(contents) == content_sha256 do
      :ok
    else
      {:error, {:content_mismatch, name}}
    end
  end

  # The content hash of the files under `directory`, or `nil` when it holds
  # none, more than the bound, or one that cannot be read.
  defp stored_content_sha256(directory) do
    paths = directory |> Path.join("**") |> Path.wildcard() |> Enum.filter(&File.regular?/1)

    if paths != [] and length(paths) <= @file_count_max do
      contents =
        Enum.reduce_while(paths, %{}, fn path, contents ->
          case File.read(path) do
            {:ok, content} ->
              {:cont, Map.put(contents, Path.relative_to(path, directory), content)}

            {:error, _reason} ->
              {:halt, nil}
          end
        end)

      case contents do
        nil -> nil
        contents -> Tarball.content_sha256(contents)
      end
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
