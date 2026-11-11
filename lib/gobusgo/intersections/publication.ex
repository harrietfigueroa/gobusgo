defmodule Gobusgo.Intersections.Publication do
  @directory "intersections"
  @manifest_prefix "intersections/manifest-"
  @manifest_time_format "%Y%m%dT%H%M%SZ"
  @reader_keep_seconds 31_536_000
  @shard_bytes_max Gobusgo.Addresses.Build.shard_bytes_max()
  @license_name "Open Database License 1.0"
  @license_url "https://opendatacommons.org/licenses/odbl/1-0/"
  @attribution "© OpenStreetMap contributors"

  @moduledoc """
  Stores built intersections through `Gobusgo.Writer`, and the manifest that
  names them.

  `Gobusgo.Addresses.Shards` cuts the streets into shards at most
  #{@shard_bytes_max} bytes before compression, the bound of the address
  shards (`Gobusgo.Addresses.Build.shard_bytes_max/0`). Each shard and the index are
  containers of `Gobusgo.Intersections.Format`, each one gzip stream at
  `#{@directory}/<prefix>-<SHA-256 of the stream>.bin.gz`, stored with a
  reader keep time of #{@reader_keep_seconds} seconds, since its name holds
  its hash. Only after every file is stored is the manifest written, at
  `#{@manifest_prefix}<UTC build time>-<SHA-256 of the index>.json`, canonical JSON:

      {"attribution": ..., "builtAt": ..., "index": {"byteSize": ..., "path": ..., "sha256": ...},
       "intersectionCount": ..., "license": {"name": ..., "url": ...}, "shards": [...],
       "sourceDate": ..., "streetCount": ...}

  A path is the URL path of the file, `/` and its destination, and a shard
  entry holds its `prefix` beside the three fields. The files are a derivative
  database of OpenStreetMap and are offered under the ODbL, which the
  manifest names. A writer stores a destination once, so each build's
  manifest has a name of its own and the reader takes the newest by name
  (`manifest/1`); the manifests of earlier builds are deleted only after the
  new one is stored, so a reader that asks at any moment finds one. Nothing
  deletes a data file: an earlier build's files stay until they are removed
  by hand.

  The writer's options are `:write_options`, the deleter's `:delete_options`,
  and the reader's, which discovery uses, `:read_options`.
  """

  alias Gobusgo.Addresses.Shards
  alias Gobusgo.Assert
  alias Gobusgo.CanonicalJson
  alias Gobusgo.Compression
  alias Gobusgo.Deleter
  alias Gobusgo.Intersections.Format
  alias Gobusgo.Intersections.Streets
  alias Gobusgo.Packed
  alias Gobusgo.Reader
  alias Gobusgo.Writer

  @type request :: %{
          source_date: String.t(),
          streets: [Streets.street(), ...],
          intersection_count: non_neg_integer(),
          built_at: DateTime.t()
        }

  @type published :: %{
          manifest_destination: String.t(),
          shard_count: pos_integer(),
          shard_byte_sizes: [pos_integer()],
          shard_expanded_byte_sizes: [pos_integer()],
          index_byte_size: pos_integer(),
          byte_count: pos_integer(),
          street_count: pos_integer()
        }

  @doc "The directory the files are stored under."
  @spec directory() :: String.t()
  def directory, do: @directory

  @doc "The prefix of every manifest's destination."
  @spec manifest_prefix() :: String.t()
  def manifest_prefix, do: @manifest_prefix

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
  @spec manifest(keyword()) :: {:ok, binary()} | {:error, Gobusgo.Reader.error_reason()}
  def manifest(options) when is_list(options) do
    request = %{prefix: @manifest_prefix, limit: 1, order: :descending, cursor: nil}

    with {:ok, %{destinations: destinations}} <- Reader.discover(request, options) do
      case destinations do
        [newest | _older] -> Reader.read(newest, options)
        [] -> {:error, :not_found}
      end
    end
  end

  @doc "How long a reader may keep a file without asking again."
  @spec reader_keep_seconds() :: pos_integer()
  def reader_keep_seconds, do: @reader_keep_seconds

  @doc "The most bytes a shard holds before compression, unless one street alone is larger."
  @spec shard_bytes_max() :: pos_integer()
  def shard_bytes_max, do: @shard_bytes_max

  @doc "Stores the shards and the index of `request`, then the manifest that names them."
  @spec publish(request(), keyword()) :: {:ok, published()} | {:error, term()}
  def publish(%{streets: [_street | _rest] = streets} = request, options) when is_list(options) do
    shards =
      Shards.split(streets, %{
        encode: &Format.encode_shard/1,
        bytes_min: &Format.shard_bytes_min/1,
        bytes_max: @shard_bytes_max
      })

    shard_files = Enum.map(shards, &shard_file/1)
    index_file = index_file(Enum.map(shard_files, & &1.entry))
    files = shard_files ++ [index_file]

    content =
      manifest_content(%{request: request, shard_files: shard_files, index_file: index_file})

    destination =
      manifest_destination(%{built_at: request.built_at, index_sha256: index_file.stored.sha256})

    with :ok <- write_all(files, Keyword.get(options, :write_options, [])),
         :ok <- write_manifest(%{destination: destination, content: content}, options),
         :ok <- delete_older_manifests(destination, options) do
      {:ok,
       %{
         manifest_destination: destination,
         shard_count: length(shard_files),
         shard_byte_sizes: Enum.map(shard_files, & &1.stored.byte_size),
         shard_expanded_byte_sizes: Enum.map(shard_files, &byte_size(&1.content)),
         index_byte_size: index_file.stored.byte_size,
         byte_count: files |> Enum.map(& &1.stored.byte_size) |> Enum.sum(),
         street_count: length(streets)
       }}
    end
  end

  defp shard_file(%{prefix: prefix, content: content}) do
    file =
      file(%{kind: Format.shard_kind(), content: Format.assert_expanded_size(:shard, content)})

    Map.put(file, :entry, %{
      prefix: prefix,
      byte_size: file.stored.byte_size,
      sha256: file.stored.sha256
    })
  end

  defp index_file(entries),
    do: file(%{kind: Format.index_kind(), content: Format.encode_index(entries)})

  # The writer compresses the content of a destination ending in the
  # compression suffix with `Gobusgo.Compression.compress/1`, which gives the
  # same stream for the same content, so the stream hashed here is the one
  # stored.
  defp file(%{kind: kind, content: content}) do
    stored = Packed.stored(content)
    destination = Packed.destination(%{directory: @directory, kind: kind, stored: stored})

    Assert.condition(
      Compression.compressed?(destination),
      "a file name ends in #{Compression.suffix()}"
    )

    %{destination: destination, content: content, stored: stored}
  end

  @doc """
  The manifest of `input.index_file` and `input.shard_files`, the files
  `publish/2` builds, as canonical JSON text.
  """
  @spec manifest_content(%{request: request(), shard_files: [map()], index_file: map()}) ::
          binary()
  def manifest_content(%{request: request, shard_files: shard_files, index_file: index_file}) do
    CanonicalJson.encode(%{
      "attribution" => @attribution,
      "builtAt" => DateTime.to_iso8601(request.built_at),
      "index" => file_entry(index_file),
      "intersectionCount" => request.intersection_count,
      "license" => %{"name" => @license_name, "url" => @license_url},
      "shards" => Enum.map(shard_files, &Map.put(file_entry(&1), "prefix", &1.entry.prefix)),
      "sourceDate" => request.source_date,
      "streetCount" => length(request.streets)
    })
  end

  defp file_entry(%{destination: destination, stored: stored}),
    do: Packed.file_entry("/" <> destination, stored)

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
