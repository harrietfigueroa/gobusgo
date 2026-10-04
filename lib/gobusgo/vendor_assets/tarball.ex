defmodule Gobusgo.VendorAssets.Tarball do
  @moduledoc """
  A package tarball held in memory: checking it against a pinned hash and
  taking files out of it. Everything here is pure.

  A tarball of the registry is a gzip-compressed tar archive whose entries
  all sit under the directory `package/`. A repository archive is one whose
  entries all sit under a single directory named after the repository.
  """

  @file_count_max 4_096

  @integrity_prefix "sha512-"
  @entry_prefix "package/"

  @doc "The integrity of `tarball` in the form a lock holds: `sha512-<base64>`."
  @spec integrity(binary()) :: String.t()
  def integrity(tarball) when is_binary(tarball) do
    @integrity_prefix <> Base.encode64(:crypto.hash(:sha512, tarball))
  end

  @doc "The lowercase hexadecimal SHA-256 of `content`."
  @spec sha256(binary()) :: String.t()
  def sha256(content) when is_binary(content) do
    Base.encode16(:crypto.hash(:sha256, content), case: :lower)
  end

  @doc """
  Returns the content of each of `paths`, paths inside the package, or the
  first path the tarball does not hold.
  """
  @spec extract(binary(), [String.t(), ...]) ::
          {:ok, %{String.t() => binary()}}
          | {:error, :tarball_invalid | {:file_missing, String.t()}}
  def extract(tarball, [_path | _rest] = paths) when is_binary(tarball) do
    entries = Enum.map(paths, &String.to_charlist(@entry_prefix <> &1))

    case :erl_tar.extract({:binary, tarball}, [:memory, :compressed, {:files, entries}]) do
      {:ok, extracted} ->
        contents =
          Map.new(extracted, fn {entry, content} ->
            {entry |> List.to_string() |> String.replace_prefix(@entry_prefix, ""), content}
          end)

        case Enum.find(paths, &(not is_map_key(contents, &1))) do
          nil -> {:ok, contents}
          path -> {:error, {:file_missing, path}}
        end

      {:error, _reason} ->
        {:error, :tarball_invalid}
    end
  end

  @doc """
  The lowercase hexadecimal SHA-256 that stands for a set of files: the hash
  of one line per file, in path order, holding the path and the SHA-256 of
  the content. It does not depend on how the files were packed.
  """
  @spec content_sha256(%{String.t() => binary()}) :: String.t()
  def content_sha256(contents) when is_map(contents) do
    contents
    |> Enum.sort_by(fn {path, _content} -> path end)
    |> Enum.map_join(fn {path, content} -> "#{path}\0#{sha256(content)}\n" end)
    |> sha256()
  end

  @doc """
  Returns the regular files of a repository archive that sit under one of
  `directories`, as a map of the path inside the repository to the content.
  A symbolic link in the archive is not a regular file and is left out. An
  archive holds at most #{@file_count_max} such files.
  """
  @spec extract_directories(binary(), [String.t(), ...]) ::
          {:ok, %{String.t() => binary()}}
          | {:error,
             :tarball_invalid
             | {:directory_missing, String.t()}
             | {:unsafe_entry, String.t()}
             | {:file_count_exceeded, pos_integer()}}
  def extract_directories(archive, [_directory | _rest] = directories) when is_binary(archive) do
    case :erl_tar.extract({:binary, archive}, [:memory, :compressed]) do
      {:ok, extracted} ->
        contents =
          for {entry, content} <- extracted,
              path = repository_path(List.to_string(entry)),
              Enum.any?(directories, &String.starts_with?(path, &1 <> "/")),
              into: %{} do
            {path, content}
          end

        check_directories(contents, directories)

      {:error, _reason} ->
        {:error, :tarball_invalid}
    end
  end

  # An entry is `<repository directory>/<path>`; the path is what remains.
  defp repository_path(entry) do
    case String.split(entry, "/", parts: 2) do
      [_repository_directory, path] -> path
      [_entry] -> ""
    end
  end

  defp check_directories(contents, directories) do
    paths = Map.keys(contents)
    file_count = length(paths)

    cond do
      file_count > @file_count_max ->
        {:error, {:file_count_exceeded, file_count}}

      unsafe = Enum.find(paths, &unsafe_path?/1) ->
        {:error, {:unsafe_entry, unsafe}}

      missing =
          Enum.find(directories, fn directory ->
            not Enum.any?(paths, &String.starts_with?(&1, directory <> "/"))
          end) ->
        {:error, {:directory_missing, missing}}

      true ->
        {:ok, contents}
    end
  end

  # A path that would leave the directory it is written under.
  defp unsafe_path?(path) do
    segments = String.split(path, "/")

    Enum.any?(segments, &(&1 in ["", ".", ".."])) or String.contains?(path, ["\\", "\0", ":"])
  end
end
