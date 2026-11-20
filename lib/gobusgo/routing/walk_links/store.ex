defmodule Gobusgo.Routing.WalkLinks.Store do
  @build_id_pattern ~r/\A[0-9a-f]{16}\z/

  @moduledoc """
  Reads the walk graph a snapshot's links are measured over from the stored
  files, through `Gobusgo.Reader`: the newest manifest, the index it names,
  and a shard by tile. The files are the ones `Gobusgo.WalkGraph.Publication`
  stores.

  A reader error is an operating error and returns as a value. A manifest or
  index that does not describe a graph this code reads, and a shard that is
  not a valid shard, are `:corrupt`: the same build gives the same answer
  again, and a caller does not read it again for it.
  """

  alias Gobusgo.Reader
  alias Gobusgo.WalkGraph.Format
  alias Gobusgo.WalkGraph.Publication
  alias Gobusgo.WalkGraph.Tiles

  @type manifest :: %{build_id: String.t(), index_destination: String.t()}

  @doc """
  The newest manifest: `{:ok, manifest}`, `:none` where no build is stored,
  or `{:error, reason}` for a read that failed (`{:io, reason}`) or a
  manifest this code does not read (`:corrupt`).
  """
  @spec manifest(keyword()) :: {:ok, manifest()} | :none | {:error, :corrupt | {:io, term()}}
  def manifest(read_options) when is_list(read_options) do
    case Publication.manifest(read_options) do
      {:ok, content} -> parse_manifest(content)
      {:error, :not_found} -> :none
      {:error, reason} -> classify(reason)
    end
  end

  @doc "The tiles that have a shard in the build `manifest` names, as a `MapSet` of `{row, column}`."
  @spec index(manifest(), keyword()) :: {:ok, MapSet.t()} | {:error, :corrupt | {:io, term()}}
  def index(%{build_id: build_id, index_destination: destination}, read_options) do
    with {:ok, content} <- read(destination, read_options),
         {:ok, %{build_id: ^build_id, tiles: tiles}} <- decode(&Format.decode_index/1, content) do
      {:ok, MapSet.new(tiles)}
    else
      {:ok, _other_build} -> {:error, :corrupt}
      {:error, _reason} = error -> error
    end
  end

  @doc """
  The function that reads the shard of a tile of the build `build_id`, as the
  bytes of its expanded container, which the measuring decodes where it uses
  them.
  """
  @spec loader(String.t(), keyword()) :: (Tiles.tile() -> {:ok, binary()} | {:error, term()})
  def loader(build_id, read_options) when is_list(read_options) do
    fn tile ->
      destination =
        "#{Publication.directory()}/" <> Format.shard_file_name(%{build_id: build_id, tile: tile})

      read(destination, read_options)
    end
  end

  defp parse_manifest(content) do
    with {:ok, %{"buildId" => build_id, "index" => %{"path" => path}} = manifest} <-
           decode_json(content),
         true <- Regex.match?(@build_id_pattern, build_id),
         true <- is_binary(path) and String.starts_with?(path, "/#{Publication.directory()}/"),
         true <- manifest["kindVersion"] == Format.version(),
         true <- manifest["unitsPerDegree"] == Format.units_per_degree(),
         true <- manifest["tile"] == tile_sizes() do
      {:ok, %{build_id: build_id, index_destination: String.trim_leading(path, "/")}}
    else
      _unreadable -> {:error, :corrupt}
    end
  end

  defp tile_sizes do
    sizes = Tiles.sizes()
    %{"latUnits" => sizes.lat, "lonUnits" => sizes.lon}
  end

  defp decode_json(content) do
    case JSON.decode(content) do
      {:ok, %{} = decoded} -> {:ok, decoded}
      _other -> {:error, :corrupt}
    end
  end

  defp read(destination, read_options) do
    case Reader.read(destination, read_options) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> classify(reason)
    end
  end

  defp decode(decoder, content) do
    case decoder.(content) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _refusal} -> {:error, :corrupt}
    end
  end

  defp classify(reason) when reason in [:content_corrupt, :content_too_large] do
    {:error, :corrupt}
  end

  defp classify(reason), do: {:error, {:io, reason}}
end
