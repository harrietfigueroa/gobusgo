defmodule Gobusgo.VendorAssets.Lock do
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
  @type t :: %{packages: [package()]}
  @type field :: :name | :version | :tarball | :integrity | :files | :path | :sha256
  @type decode_error ::
          :invalid_json
          | {:schema_mismatch, Schema.mismatch()}
          | {:package_count_exceeded, pos_integer()}
          | {:duplicate_package, String.t()}
          | {:invalid_package, String.t(), field()}

  @doc "A lock with no package."
  @spec empty() :: t()
  def empty, do: %{packages: []}

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
         :ok <- check_packages(packages) do
      {:ok, %{packages: Enum.sort_by(packages, & &1.name)}}
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
  def put_package(%{packages: packages}, %{name: name} = package) do
    others = Enum.reject(packages, &(&1.name == name))
    %{packages: Enum.sort_by([package | others], & &1.name)}
  end

  @doc "Returns the text of `lock`, which `decode/1` reads back."
  @spec encode(t()) :: binary()
  def encode(%{packages: packages}) do
    encoded = packages |> Enum.sort_by(& &1.name) |> Enum.map_join(",\n", &encode_package/1)

    case encoded do
      "" -> ~s({\n  "packages": []\n}\n)
      encoded -> ~s({\n  "packages": [\n#{encoded}\n  ]\n}\n)
    end
  end

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

  defp check_packages(packages) do
    package_count = length(packages)
    names = Enum.map(packages, & &1.name)

    cond do
      package_count > @package_count_max ->
        {:error, {:package_count_exceeded, package_count}}

      names != Enum.uniq(names) ->
        {:error, {:duplicate_package, List.first(names -- Enum.uniq(names))}}

      true ->
        case Enum.find_value(packages, &invalid_package/1) do
          nil -> :ok
          invalid -> {:error, invalid}
        end
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
end
