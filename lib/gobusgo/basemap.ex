defmodule Gobusgo.Basemap do
  @manifest_bytes_max 1_048_576
  @manifest_name "manifest.json"

  @moduledoc """
  The basemap a directory holds: the manifest of the extraction that wrote
  its archives.

  `read_manifest/1` reads `#{@manifest_name}` in the directory, at most
  #{@manifest_bytes_max} bytes of it, and returns the manifest or why there
  is none: `:not_found` for a directory with no manifest, the state before
  any extraction; `:too_large`; `{:read, reason}` for a file that cannot be
  read; or the rule `Gobusgo.Basemap.Manifest.decode/1` names.
  """

  alias Gobusgo.Basemap.Manifest

  @doc "Reads the manifest of the basemap in `dir`."
  @spec read_manifest(String.t()) ::
          {:ok, Manifest.t()}
          | {:error, :not_found | :too_large | {:read, File.posix()} | Manifest.decode_error()}
  def read_manifest(dir) when is_binary(dir) do
    path = Path.join(dir, @manifest_name)

    case File.stat(path) do
      {:ok, %{size: size}} when size > @manifest_bytes_max -> {:error, :too_large}
      {:ok, _stat} -> read(path)
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, {:read, reason}}
    end
  end

  defp read(path) do
    case File.read(path) do
      {:ok, content} -> Manifest.decode(content)
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, {:read, reason}}
    end
  end
end
