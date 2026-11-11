defmodule Gobusgo.Places.Publication do
  @directory "places"
  @manifest_destination "places/manifest.json"
  @reader_keep_seconds 31_536_000

  @moduledoc """
  Stores a built places file through `Gobusgo.Writer`, and the manifest that
  names it.

  The file is the container of `Gobusgo.Places.Format` as one gzip stream at
  `#{@directory}/places-<SHA-256 of the stream>.bin.gz`, stored with a
  reader keep time of #{@reader_keep_seconds} seconds, since its name holds
  its hash. Only after the file is stored is `#{@manifest_destination}`
  written, canonical JSON naming it:

      {"builtAt": ..., "file": {"byteSize": ..., "path": ..., "sha256": ...},
       "kind": 5, "kindVersion": 1, "placeCount": ..., "sourceDate": ...}

  `file` is `Gobusgo.Packed.file_entry/2`, whose `path` is the destination.
  The manifest changes with every build, so the previous one is deleted
  before the new one is written; a reader that asks between the two finds
  none. Nothing deletes a file: an earlier file stays until it is removed
  by hand.

  The writer's options are `:write_options` and the deleter's
  `:delete_options`.
  """

  alias Gobusgo.Assert
  alias Gobusgo.CanonicalJson
  alias Gobusgo.Deleter
  alias Gobusgo.Packed
  alias Gobusgo.Places.Format
  alias Gobusgo.Places.Selection
  alias Gobusgo.Writer

  @type request :: %{
          source_date: String.t(),
          places: [Selection.candidate()],
          built_at: DateTime.t()
        }

  @type published :: %{
          file_destination: String.t(),
          manifest_destination: String.t(),
          expanded_bytes: pos_integer(),
          byte_size: pos_integer(),
          sha256: String.t(),
          place_count: non_neg_integer()
        }

  @doc "The directory the places files are stored under."
  @spec directory() :: String.t()
  def directory, do: @directory

  @doc "The destination of the manifest."
  @spec manifest_destination() :: String.t()
  def manifest_destination, do: @manifest_destination

  @doc "How long a reader may keep a places file without asking again."
  @spec reader_keep_seconds() :: pos_integer()
  def reader_keep_seconds, do: @reader_keep_seconds

  @doc """
  The manifest of the file stored at `input.destination`, as canonical JSON
  text, for `input.stored` built from `input.place_count` places of source
  date `input.source_date` at `input.built_at`.
  """
  @spec manifest(%{
          destination: String.t(),
          stored: Packed.stored(),
          place_count: non_neg_integer(),
          source_date: String.t(),
          built_at: DateTime.t()
        }) :: binary()
  def manifest(%{destination: destination, stored: stored, built_at: built_at} = input) do
    CanonicalJson.encode(%{
      "file" => Packed.file_entry(destination, stored),
      "kind" => Format.kind(),
      "kindVersion" => Format.version(),
      "placeCount" => input.place_count,
      "sourceDate" => input.source_date,
      "builtAt" => DateTime.to_iso8601(built_at)
    })
  end

  @doc "Stores the file of `request`, then the manifest that names it."
  @spec publish(request(), keyword()) :: {:ok, published()} | {:error, term()}
  def publish(%{source_date: source_date, places: places, built_at: built_at}, options)
      when is_list(options) do
    content = Format.encode(%{source_date: source_date, places: places})

    Assert.condition(
      byte_size(content) <= Format.expanded_bytes_max(),
      "a places file expands to at most #{Format.expanded_bytes_max()} bytes, got: #{byte_size(content)}"
    )

    stored = Packed.stored(content)

    destination =
      Packed.destination(%{directory: @directory, kind: Format.kind(), stored: stored})

    manifest =
      manifest(%{
        destination: destination,
        stored: stored,
        place_count: length(places),
        source_date: source_date,
        built_at: built_at
      })

    with :ok <- write_file(destination, stored, Keyword.get(options, :write_options, [])),
         :ok <- replace_manifest(manifest, options) do
      {:ok,
       %{
         file_destination: destination,
         manifest_destination: @manifest_destination,
         expanded_bytes: byte_size(content),
         byte_size: stored.byte_size,
         sha256: stored.sha256,
         place_count: length(places)
       }}
    end
  end

  # A file of the same name holds the same content, so one already there is stored.
  defp write_file(destination, stored, write_options) do
    request = %{
      destination: destination,
      content: stored.content,
      reader_keep_seconds: @reader_keep_seconds
    }

    case Writer.write(request, write_options) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
      {:error, reason} -> {:error, {:write_file, reason}}
    end
  end

  defp replace_manifest(manifest, options) do
    delete = %{destination: @manifest_destination, within: @directory <> "/"}

    with :ok <- delete_manifest(Deleter.delete(delete, Keyword.get(options, :delete_options, []))),
         :ok <-
           Writer.write(
             %{destination: @manifest_destination, content: manifest},
             Keyword.get(options, :write_options, [])
           ) do
      :ok
    else
      {:error, reason} -> {:error, {:write_manifest, reason}}
    end
  end

  defp delete_manifest(:ok), do: :ok
  defp delete_manifest({:error, :not_found}), do: :ok
  defp delete_manifest({:error, _reason} = failure), do: failure
end
