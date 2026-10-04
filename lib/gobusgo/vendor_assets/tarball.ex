defmodule Gobusgo.VendorAssets.Tarball do
  @moduledoc """
  A package tarball held in memory: checking it against a pinned hash and
  taking files out of it. Everything here is pure.

  A tarball of the registry is a gzip-compressed tar archive whose entries
  all sit under the directory `package/`.
  """

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
end
