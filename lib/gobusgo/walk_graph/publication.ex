defmodule Gobusgo.WalkGraph.Publication do
  @directory "intersections"
  @manifest_prefix "intersections/walking-manifest-"
  @manifest_time_format "%Y%m%dT%H%M%SZ"
  @reader_keep_seconds 31_536_000
  @build_id_hex_digits 16
  @license_name "Open Database License 1.0"
  @license_url "https://opendatacommons.org/licenses/odbl/1-0/"
  @attribution "© OpenStreetMap contributors"

  @moduledoc """
  Stores a built walk graph through `Gobusgo.Writer`, and the manifest that
  names it.

  Each tile's pieces are ordered and encoded as a shard of
  `Gobusgo.WalkGraph.Format`, one gzip stream at
  `#{@directory}/walk-graph-<build identifier>-<row>_<column>.bin.gz`. The
  build identifier is the first #{@build_id_hex_digits} hexadecimal digits of the SHA-256 of the
  lines `<row> <column> <SHA-256 of the shard's stream>`, one per tile in
  order, so a name fixes its file's content and the files are stored with a
  reader keep time of #{@reader_keep_seconds} seconds. The index, a file of
  its own at `#{@directory}/walk-graph-index-<SHA-256 of the stream>.bin.gz`,
  names the tiles that have a shard. Only after every file is stored is the
  manifest written, at `#{@manifest_prefix}<UTC build time>-<SHA-256 of the
  index>.json`, canonical JSON:

      {"attribution": ..., "buildId": ..., "builtAt": ..., "index": {"byteSize": ..., "path": ..., "sha256": ...}, "kindVersion": ...,
       "license": {"name": ..., "url": ...}, "pieceCount": ..., "shardCount": ...,
       "sourceDate": ..., "tile": {"latUnits": ..., "lonUnits": ...}, "unitsPerDegree": ...}

  A path is the URL path of the file, `/` and its destination. The files are
  a derivative database of OpenStreetMap and are offered under the ODbL,
  which the manifest names, from the directory of the intersection files
  (`Gobusgo.Intersections.Publication`), whose manifests are under another
  prefix. A writer stores a destination once, so each build's manifest has a
  name of its own and the reader takes the newest by name (`manifest/1`);
  the manifests of earlier builds are deleted only after the new one is
  stored. Nothing deletes a data file: an earlier build's files stay until
  they are removed by hand.

  The writer's options are `:write_options`, the deleter's `:delete_options`,
  and the reader's, which discovery uses, `:read_options`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.CanonicalJson
  alias Gobusgo.Compression
  alias Gobusgo.Deleter
  alias Gobusgo.Packed
  alias Gobusgo.Reader
  alias Gobusgo.WalkGraph.Format
  alias Gobusgo.WalkGraph.Selection
  alias Gobusgo.WalkGraph.Tiles
  alias Gobusgo.Writer

  @type request :: %{
          source_date: String.t(),
          tiles: %{Tiles.tile() => [Selection.piece(), ...]},
          built_at: DateTime.t()
        }

  @type published :: %{
          manifest_destination: String.t(),
          build_id: String.t(),
          shard_count: pos_integer(),
          shard_byte_sizes: [pos_integer()],
          shard_expanded_byte_sizes: [pos_integer()],
          index_byte_size: pos_integer(),
          byte_count: pos_integer()
        }

  @doc "The directory the files are stored under."
  @spec directory() :: String.t()
  def directory, do: @directory

  @doc "The prefix of every manifest's destination."
  @spec manifest_prefix() :: String.t()
  def manifest_prefix, do: @manifest_prefix

  @doc "How long a reader may keep a file without asking again."
  @spec reader_keep_seconds() :: pos_integer()
  def reader_keep_seconds, do: @reader_keep_seconds

  @doc "The destination of the manifest of a build made at `built_at` whose index has the SHA-256 `index_sha256`."
  @spec manifest_destination(%{built_at: DateTime.t(), index_sha256: String.t()}) :: String.t()
  def manifest_destination(%{built_at: built_at, index_sha256: index_sha256})
      when is_binary(index_sha256) do
    time = Calendar.strftime(built_at, @manifest_time_format)
    "#{@manifest_prefix}#{time}-#{index_sha256}.json"
  end

  @doc """
  The newest stored manifest's content, or the reason there is none:
  `{:error, :not_found}` where no build is stored. `options` are the
  reader's.
  """
  @spec manifest(keyword()) :: {:ok, binary()} | {:error, Reader.error_reason()}
  def manifest(options) when is_list(options) do
    request = %{prefix: @manifest_prefix, limit: 1, order: :descending, cursor: nil}

    with {:ok, %{destinations: destinations}} <- Reader.discover(request, options) do
      case destinations do
        [newest | _older] -> Reader.read(newest, options)
        [] -> {:error, :not_found}
      end
    end
  end

  @doc "Stores the shards and the index of `request`, then the manifest that names them."
  @spec publish(request(), keyword()) :: {:ok, published()} | {:error, term()}
  def publish(%{tiles: tiles} = request, options) when map_size(tiles) > 0 and is_list(options) do
    encoded = encode_shards(tiles)
    build_id = build_id(encoded)
    shard_files = Enum.map(encoded, &shard_file(&1, build_id))
    index_file = index_file(%{build_id: build_id, tiles: Enum.map(encoded, & &1.tile)})
    files = shard_files ++ [index_file]

    content =
      manifest_content(%{
        request: request,
        build_id: build_id,
        shard_count: length(shard_files),
        index_file: index_file,
        piece_count: piece_count(tiles)
      })

    destination =
      manifest_destination(%{built_at: request.built_at, index_sha256: index_file.stored.sha256})

    with :ok <- write_all(files, Keyword.get(options, :write_options, [])),
         :ok <- write_manifest(%{destination: destination, content: content}, options),
         :ok <- delete_older_manifests(destination, options) do
      {:ok,
       %{
         manifest_destination: destination,
         build_id: build_id,
         shard_count: length(shard_files),
         shard_byte_sizes: Enum.map(shard_files, & &1.stored.byte_size),
         shard_expanded_byte_sizes: Enum.map(shard_files, &byte_size(&1.content)),
         index_byte_size: index_file.stored.byte_size,
         byte_count: files |> Enum.map(& &1.stored.byte_size) |> Enum.sum()
       }}
    end
  end

  defp piece_count(tiles), do: tiles |> Map.values() |> Enum.map(&length/1) |> Enum.sum()

  # The tiles in the order of their rows and then columns, each encoded and
  # compressed once.
  defp encode_shards(tiles) do
    for tile <- tiles |> Map.keys() |> Enum.sort() do
      ordered = Format.order(Map.fetch!(tiles, tile), %{tile: tile, tile_sizes: Tiles.sizes()})
      content = Format.assert_expanded_size(:shard, Format.encode_shard(ordered))
      %{tile: tile, content: content, stored: Packed.stored(content)}
    end
  end

  @doc "The identifier of a build whose shards are `encoded`, each `%{tile:, stored:}` in tile order."
  @spec build_id([%{tile: Tiles.tile(), stored: %{sha256: String.t()}}]) :: String.t()
  def build_id(encoded) when is_list(encoded) do
    lines =
      for %{tile: {row, column}, stored: %{sha256: sha256}} <- encoded,
          do: "#{row} #{column} #{sha256}\n"

    digest = :crypto.hash(:sha256, lines) |> Base.encode16(case: :lower)
    binary_part(digest, 0, @build_id_hex_digits)
  end

  defp shard_file(%{tile: tile, content: content, stored: stored}, build_id) do
    destination = "#{@directory}/" <> Format.shard_file_name(%{build_id: build_id, tile: tile})
    assert_compressed(destination)
    %{destination: destination, content: content, stored: stored}
  end

  defp index_file(%{build_id: _build_id, tiles: _tiles} = index) do
    content = Format.encode_index(index)
    stored = Packed.stored(content)

    destination =
      Packed.destination(%{directory: @directory, kind: Format.index_kind(), stored: stored})

    assert_compressed(destination)
    %{destination: destination, content: content, stored: stored}
  end

  # The writer compresses the content of a destination that ends in the
  # compression suffix with `Gobusgo.Compression.compress/1`, which gives the
  # same stream for the same content, so the stream hashed here is the one
  # stored.
  defp assert_compressed(destination) do
    Assert.condition(
      Compression.compressed?(destination),
      "a file name ends in #{Compression.suffix()}"
    )
  end

  @doc "The manifest of a build as canonical JSON text."
  @spec manifest_content(%{
          request: request(),
          build_id: String.t(),
          shard_count: pos_integer(),
          index_file: map(),
          piece_count: pos_integer()
        }) :: binary()
  def manifest_content(%{
        request: request,
        build_id: build_id,
        shard_count: shard_count,
        index_file: index_file,
        piece_count: piece_count
      }) do
    sizes = Tiles.sizes()

    CanonicalJson.encode(%{
      "attribution" => @attribution,
      "buildId" => build_id,
      "builtAt" => DateTime.to_iso8601(request.built_at),
      "index" => Packed.file_entry("/" <> index_file.destination, index_file.stored),
      "kindVersion" => Format.version(),
      "license" => %{"name" => @license_name, "url" => @license_url},
      "pieceCount" => piece_count,
      "shardCount" => shard_count,
      "sourceDate" => request.source_date,
      "tile" => %{"latUnits" => sizes.lat, "lonUnits" => sizes.lon},
      "unitsPerDegree" => Format.units_per_degree()
    })
  end

  # A file of the same name holds the same content, so one already there is stored.
  defp write_all(files, write_options) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      request = %{
        destination: file.destination,
        content: file.content,
        reader_keep_seconds: @reader_keep_seconds
      }

      case Writer.write(request, write_options) do
        :ok -> {:cont, :ok}
        {:error, :already_exists} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:write_file, reason}}}
      end
    end)
  end

  # A manifest of the same name names the same index, so one already there is stored.
  defp write_manifest(%{destination: destination, content: content}, options) do
    request = %{destination: destination, content: content}

    case Writer.write(request, Keyword.get(options, :write_options, [])) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
      {:error, reason} -> {:error, {:write_manifest, reason}}
    end
  end

  # The manifests are listed oldest first, at most one page of them: a build
  # leaves one, so a listing that does not fit a page is a fault.
  defp delete_older_manifests(current, options) do
    request = %{
      prefix: @manifest_prefix,
      limit: Reader.discovery_limit_max(),
      order: :ascending,
      cursor: nil
    }

    with {:ok, %{destinations: destinations, cursor: cursor}} <-
           Reader.discover(request, Keyword.get(options, :read_options, [])),
         true <- is_nil(cursor) do
      delete_all(Enum.reject(destinations, &(&1 == current)), options)
    else
      false -> {:error, {:delete_manifests, :too_many_manifests}}
      {:error, reason} -> {:error, {:delete_manifests, reason}}
    end
  end

  defp delete_all(destinations, options) do
    delete_options = Keyword.get(options, :delete_options, [])

    Enum.reduce_while(destinations, :ok, fn destination, :ok ->
      request = %{destination: destination, within: @directory <> "/"}

      case Deleter.delete(request, delete_options) do
        :ok -> {:cont, :ok}
        {:error, :not_found} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:delete_manifests, reason}}}
      end
    end)
  end
end
