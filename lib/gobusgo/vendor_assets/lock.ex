defmodule Gobusgo.VendorAssets.Lock do
  @archive_count_max 8
  @directory_count_max 8
  @file_count_max 32
  @package_count_max 32

  @moduledoc """
  The lock file of the vendored front-end packages: which version of each
  package is in use, and the hashes that pin its content. Everything here is
  pure.

  A lock holds at most #{@package_count_max} packages, each with a distinct
  name and at most #{@file_count_max} files:

    * `name`: the package's name in the registry
    * `version`: the pinned version
    * `tarball`: the address of that version's tarball, on the registry's
      host over HTTPS
    * `integrity`: the registry's SHA-512 of the tarball, written
      `sha512-<base64>`
    * `files`: the files taken out of the tarball, each with its `path`
      inside the package and the lowercase hexadecimal `sha256` of its
      content

  A lock also holds at most #{@archive_count_max} archives, each a
  repository at a commit, with a name no package has:

    * `name`: the name the archive's files are written under
    * `repository`: the GitHub repository, `owner/name`
    * `commit`: the pinned commit, 40 hexadecimal digits
    * `directories`: at most #{@directory_count_max} directories taken out
      of the repository
    * `contentSha256`: the hash of the files taken, as
      `Gobusgo.VendorAssets.Tarball.content_sha256/1` computes it
    * `fileCount`: how many files that is

  `encode/1` writes the packages in name order and the files in path order,
  one value per line, so a change of version is a small diff.
  """

  alias Gobusgo.Schema

  @registry_host "registry.npmjs.org"
  @integrity_prefix "sha512-"
  @sha512_byte_count 64
  # A plain or scoped name: https://docs.npmjs.com/cli/v11/configuring-npm/package-json#name — checked 2026-10-04
  @name_pattern ~r/\A(@[a-z0-9][a-z0-9._-]*\/)?[a-z0-9][a-z0-9._-]*\z/
  @version_pattern ~r/\A[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?\z/
  @path_segment_pattern ~r/\A[A-Za-z0-9_-][A-Za-z0-9._-]*\z/
  @sha256_pattern ~r/\A[0-9a-f]{64}\z/
  @repository_pattern ~r/\A[A-Za-z0-9][A-Za-z0-9-]*\/[A-Za-z0-9._-]+\z/
  @commit_pattern ~r/\A[0-9a-f]{40}\z/

  @schema {:map,
           %{
             "packages" =>
               {:list,
                {:map,
                 %{
                   "name" => :string,
                   "version" => :string,
                   "tarball" => :string,
                   "integrity" => :string,
                   "files" => {:list, {:map, %{"path" => :string, "sha256" => :string}}}
                 }}},
             "archives" =>
               {:list,
                {:map,
                 %{
                   "name" => :string,
                   "repository" => :string,
                   "commit" => :string,
                   "directories" => {:list, :string},
                   "contentSha256" => :string,
                   "fileCount" => :integer
                 }}}
           }}

  @type file :: %{path: String.t(), sha256: String.t()}
  @type package :: %{
          name: String.t(),
          version: String.t(),
          tarball: String.t(),
          integrity: String.t(),
          files: [file(), ...]
        }
  @type archive :: %{
          name: String.t(),
          repository: String.t(),
          commit: String.t(),
          directories: [String.t(), ...],
          content_sha256: String.t(),
          file_count: pos_integer()
        }
  @type t :: %{packages: [package()], archives: [archive()]}
  @type field ::
          :name
          | :version
          | :tarball
          | :integrity
          | :files
          | :path
          | :sha256
          | :repository
          | :commit
          | :directories
          | :content_sha256
          | :file_count
  @type decode_error ::
          :invalid_json
          | {:schema_mismatch, Schema.mismatch()}
          | {:package_count_exceeded, pos_integer()}
          | {:archive_count_exceeded, pos_integer()}
          | {:duplicate_name, String.t()}
          | {:invalid_package, String.t(), field()}
          | {:invalid_archive, String.t(), field()}

  @doc "A lock with no package and no archive."
  @spec empty() :: t()
  def empty, do: %{packages: [], archives: []}

  @doc "Returns whether `repository` is a GitHub repository written `owner/name`."
  @spec valid_repository?(term()) :: boolean()
  def valid_repository?(repository) do
    is_binary(repository) and repository =~ @repository_pattern and
      not String.contains?(repository, "..")
  end

  @doc "Returns whether `commit` is a commit: 40 lowercase hexadecimal digits."
  @spec valid_commit?(term()) :: boolean()
  def valid_commit?(commit), do: is_binary(commit) and commit =~ @commit_pattern

  @doc """
  Returns the field of `archive` that breaks the lock's rules, or `nil` when
  the archive obeys them.
  """
  @spec invalid_archive_field(archive()) :: field() | nil
  def invalid_archive_field(%{name: name, directories: directories} = archive) do
    cond do
      not valid_path?(name) -> :name
      String.contains?(name, "/") -> :name
      not valid_repository?(archive.repository) -> :repository
      not valid_commit?(archive.commit) -> :commit
      directories == [] -> :directories
      length(directories) > @directory_count_max -> :directories
      Enum.uniq(directories) != directories -> :directories
      not Enum.all?(directories, &valid_path?/1) -> :directories
      not (archive.content_sha256 =~ @sha256_pattern) -> :content_sha256
      archive.file_count < 1 -> :file_count
      true -> nil
    end
  end

  @doc "Returns whether `name` is a package name."
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name), do: is_binary(name) and name =~ @name_pattern

  @doc "Returns whether `version` is a version number."
  @spec valid_version?(term()) :: boolean()
  def valid_version?(version), do: is_binary(version) and version =~ @version_pattern

  @doc """
  Returns whether `path` names a file inside a package: segments of letters,
  digits, `.`, `_`, and `-` joined by `/`, none starting with `.`.
  """
  @spec valid_path?(term()) :: boolean()
  def valid_path?(path) when is_binary(path) do
    path |> String.split("/") |> Enum.all?(&(&1 =~ @path_segment_pattern))
  end

  def valid_path?(_path), do: false

  @doc """
  Returns the field of `package` that breaks the lock's rules, or `nil` when
  the package obeys them.
  """
  @spec invalid_field(package()) :: field() | nil
  def invalid_field(%{
        name: name,
        version: version,
        tarball: tarball,
        integrity: integrity,
        files: files
      }) do
    cond do
      not valid_name?(name) -> :name
      not valid_version?(version) -> :version
      not valid_tarball?(tarball) -> :tarball
      not valid_integrity?(integrity) -> :integrity
      files == [] -> :files
      length(files) > @file_count_max -> :files
      Enum.uniq_by(files, & &1.path) != files -> :files
      not Enum.all?(files, &valid_path?(&1.path)) -> :path
      not Enum.all?(files, &(&1.sha256 =~ @sha256_pattern)) -> :sha256
      true -> nil
    end
  end

  @doc "Returns the lock that `content` holds, or the first rule it breaks."
  @spec decode(binary()) :: {:ok, t()} | {:error, decode_error()}
  def decode(content) when is_binary(content) do
    with {:ok, decoded} <- decode_json(content),
         nil <- Schema.mismatch(decoded, @schema),
         packages = Enum.map(decoded["packages"], &package/1),
         archives = Enum.map(decoded["archives"], &archive/1),
         :ok <- check_counts(packages, archives),
         :ok <- check_entries(packages, archives) do
      {:ok,
       %{packages: Enum.sort_by(packages, & &1.name), archives: Enum.sort_by(archives, & &1.name)}}
    else
      %{path: _path} = mismatch -> {:error, {:schema_mismatch, mismatch}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Returns the package named `name`, or `:error` when the lock has none."
  @spec fetch_package(t(), String.t()) :: {:ok, package()} | :error
  def fetch_package(%{packages: packages}, name) when is_binary(name) do
    case Enum.find(packages, &(&1.name == name)) do
      nil -> :error
      package -> {:ok, package}
    end
  end

  @doc """
  Returns `lock` with `package` in place of the package of the same name, or
  added when the lock has none. The caller guarantees a package that obeys
  the lock's rules.
  """
  @spec put_package(t(), package()) :: t()
  def put_package(%{packages: packages} = lock, %{name: name} = package) do
    others = Enum.reject(packages, &(&1.name == name))
    %{lock | packages: Enum.sort_by([package | others], & &1.name)}
  end

  @doc "Returns the archive named `name`, or `:error` when the lock has none."
  @spec fetch_archive(t(), String.t()) :: {:ok, archive()} | :error
  def fetch_archive(%{archives: archives}, name) when is_binary(name) do
    case Enum.find(archives, &(&1.name == name)) do
      nil -> :error
      archive -> {:ok, archive}
    end
  end

  @doc """
  Returns `lock` with `archive` in place of the archive of the same name, or
  added when the lock has none. The caller guarantees an archive that obeys
  the lock's rules.
  """
  @spec put_archive(t(), archive()) :: t()
  def put_archive(%{archives: archives} = lock, %{name: name} = archive) do
    others = Enum.reject(archives, &(&1.name == name))
    %{lock | archives: Enum.sort_by([archive | others], & &1.name)}
  end

  @doc "Returns the text of `lock`, which `decode/1` reads back."
  @spec encode(t()) :: binary()
  def encode(%{packages: packages, archives: archives}) do
    encoded_packages = packages |> Enum.sort_by(& &1.name) |> Enum.map(&encode_package/1)
    encoded_archives = archives |> Enum.sort_by(& &1.name) |> Enum.map(&encode_archive/1)

    ~s({\n  "packages": #{encode_list(encoded_packages)},\n  "archives": #{encode_list(encoded_archives)}\n}\n)
  end

  defp encode_list([]), do: "[]"
  defp encode_list(encoded), do: "[\n" <> Enum.join(encoded, ",\n") <> "\n  ]"

  defp decode_json(content) do
    case JSON.decode(content) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _reason} -> {:error, :invalid_json}
    end
  end

  defp package(%{"files" => files} = package) do
    %{
      name: package["name"],
      version: package["version"],
      tarball: package["tarball"],
      integrity: package["integrity"],
      files:
        files |> Enum.map(&%{path: &1["path"], sha256: &1["sha256"]}) |> Enum.sort_by(& &1.path)
    }
  end

  defp archive(archive) do
    %{
      name: archive["name"],
      repository: archive["repository"],
      commit: archive["commit"],
      directories: Enum.sort(archive["directories"]),
      content_sha256: archive["contentSha256"],
      file_count: archive["fileCount"]
    }
  end

  defp check_counts(packages, archives) do
    package_count = length(packages)
    archive_count = length(archives)
    names = Enum.map(packages, & &1.name) ++ Enum.map(archives, & &1.name)

    cond do
      package_count > @package_count_max ->
        {:error, {:package_count_exceeded, package_count}}

      archive_count > @archive_count_max ->
        {:error, {:archive_count_exceeded, archive_count}}

      names != Enum.uniq(names) ->
        {:error, {:duplicate_name, List.first(names -- Enum.uniq(names))}}

      true ->
        :ok
    end
  end

  defp check_entries(packages, archives) do
    invalid =
      Enum.find_value(packages, &invalid_package/1) ||
        Enum.find_value(archives, &invalid_archive/1)

    case invalid do
      nil -> :ok
      invalid -> {:error, invalid}
    end
  end

  defp invalid_archive(%{name: name} = archive) do
    case invalid_archive_field(archive) do
      nil -> nil
      field -> {:invalid_archive, name, field}
    end
  end

  defp invalid_package(%{name: name} = package) do
    case invalid_field(package) do
      nil -> nil
      field -> {:invalid_package, name, field}
    end
  end

  @doc "Returns whether `tarball` is a tarball address on the registry's host over HTTPS."
  @spec valid_tarball?(term()) :: boolean()
  def valid_tarball?(tarball) when is_binary(tarball) do
    case URI.parse(tarball) do
      %URI{
        scheme: "https",
        host: @registry_host,
        port: 443,
        userinfo: nil,
        query: nil,
        fragment: nil
      } ->
        String.ends_with?(tarball, ".tgz")

      _other ->
        false
    end
  end

  def valid_tarball?(_tarball), do: false

  @doc "Returns whether `integrity` is a SHA-512 written `sha512-<base64>`."
  @spec valid_integrity?(term()) :: boolean()
  def valid_integrity?(@integrity_prefix <> encoded) do
    case Base.decode64(encoded) do
      {:ok, digest} -> byte_size(digest) == @sha512_byte_count
      :error -> false
    end
  end

  def valid_integrity?(_integrity), do: false

  defp encode_package(%{files: files} = package) do
    encoded_files =
      files
      |> Enum.sort_by(& &1.path)
      |> Enum.map_join(",\n", fn %{path: path, sha256: sha256} ->
        ~s(        {"path": #{JSON.encode!(path)}, "sha256": #{JSON.encode!(sha256)}})
      end)

    """
        {
          "name": #{JSON.encode!(package.name)},
          "version": #{JSON.encode!(package.version)},
          "tarball": #{JSON.encode!(package.tarball)},
          "integrity": #{JSON.encode!(package.integrity)},
          "files": [
    #{encoded_files}
          ]
        }\
    """
  end

  defp encode_archive(archive) do
    encoded_directories = Enum.map_join(Enum.sort(archive.directories), ", ", &JSON.encode!/1)

    """
        {
          "name": #{JSON.encode!(archive.name)},
          "repository": #{JSON.encode!(archive.repository)},
          "commit": #{JSON.encode!(archive.commit)},
          "directories": [#{encoded_directories}],
          "contentSha256": #{JSON.encode!(archive.content_sha256)},
          "fileCount": #{archive.file_count}
        }\
    """
  end
end
