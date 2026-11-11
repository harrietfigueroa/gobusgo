defmodule Gobusgo.Addresses.Build do
  @shard_bytes_max 131_072
  @download_bytes_max 536_870_912
  @heap_words_max 40_000_000
  @sample_interval_ms 100

  @moduledoc """
  One run of the address build: fetches each county's whole address layer
  into a file of its own, reads them one after another into the streets the
  shards hold, and, when what it read is not what the current build holds or
  the current build is not from today, cuts the streets into shards, writes
  every file through `Gobusgo.Writer`, and hands the manifest to
  `Gobusgo.Addresses`. One run publishes every county's addresses in one set
  of files.

  Every county is fetched before any is read, in the order of `:sources`,
  and the run ends at the first county whose fetch does not give a file. An
  export that is older than its layer is a stale export
  (`Gobusgo.Addresses.Source`), a known outcome that leaves the current
  files in place, as does a failed fetch of any county: a build is the
  addresses of every county or nothing, so no build ever lacks a county the
  one before it held. A county's file is deleted once it is read, and the
  rest when the run ends.

  The streets are cut into shards by `Gobusgo.Addresses.Shards`, each at
  most #{@shard_bytes_max} bytes as `Gobusgo.Addresses.Format` writes it,
  before compression. A file is a packed container (`Gobusgo.Packed`),
  named by the SHA-256 of its gzip stream and stored at
  `addresses/dt=<build date>/<name>`, so the same
  bytes have the same name on every day and a build on another day writes
  the files again under that day. The manifest is stored last, after every
  file it names, at `addresses/dt=<build date>/manifest-<build time>-<SHA-256
  of the input>.json`, so a start finds the newest build by its newest
  manifest.

  A run whose input hashes to that of the current build, and whose current
  build is from today, builds nothing. The hash is of what the accumulator
  holds after the bounds are applied, so a change to the basemap's bounds
  changes it.

  ## Logs

  One line per run, at the decision point:

    * `Address shards built` at `info`, with the counts of records read,
      accepted, and left out by cause, the counts of streets, addresses,
      and shards, the bytes written, the sizes of the export and the
      times each step took, and the peak heap of the build in words.
    * `Address shards unchanged` at `info`, with the counts and times.
    * `Address export stale` at `warning`, with the `source` and why, when
      its export is older than its layer; the current files stay.
    * `Address shards not built` at `error`, with the `reason`, when a
      request or a write failed or the records read of a county differ in
      count from its layer's.
    * `Address shard build killed` at `error` when the build outgrows its
      heap cap.

  The build holds a street's addresses as packed rows
  (`Gobusgo.Addresses.Rows`) and runs in a process of its own whose heap is
  capped at `:heap_words_max` words and that collects its whole heap at
  every collection, so garbage of the earlier steps is not kept in an old
  generation.

  ## Options

    * `:server` (required): the `Gobusgo.Addresses` process.
    * `:sources`: a list of `{module, options}`, each a
      `Gobusgo.Addresses.Source` module with the options of its `fetch/2`.
      Defaults to King, Pierce, and Snohomish counties' with no options.
    * `:work_directory`: where the exports are written, a directory of its
      own for each source. Defaults to a
      directory of the system's temporary directory.
    * `:bounds`: `{:bounds, bounds}` to keep the positions inside `bounds`
      or `:none` for every position. Defaults to the bounds of the basemap's
      manifest, or `:none` where the base directory holds none.
    * `:clock`: returns the current UTC time. Defaults to `DateTime.utc_now/0`.
    * `:write_options`: options for `Gobusgo.Writer.write/2`.
    * `:shard_bytes_max`: the most bytes of a shard's content, before
      compression. Defaults to #{@shard_bytes_max}.
    * `:download_bytes_max`: the most bytes of each export. Defaults to
      #{@download_bytes_max}.
    * `:heap_words_max`: the heap cap of the build, in words. Defaults to
      #{@heap_words_max}.
  """

  require Logger

  alias Gobusgo.Addresses
  alias Gobusgo.Addresses.Accumulator
  alias Gobusgo.Addresses.Format
  alias Gobusgo.Addresses.Shards
  alias Gobusgo.Assert
  alias Gobusgo.CanonicalJson
  alias Gobusgo.Compression
  alias Gobusgo.Packed
  alias Gobusgo.Writer

  @type outcome ::
          {:built, map()}
          | {:unchanged, map()}
          | {:stale, map()}
          | {:failed, term()}

  @doc "The most bytes of a shard's content, before compression."
  @spec shard_bytes_max() :: pos_integer()
  def shard_bytes_max, do: @shard_bytes_max

  @doc "Runs one build and logs its outcome."
  @spec run(keyword()) :: {:ok, map()} | {:error, term()}
  def run(options) when is_list(options) do
    options =
      Keyword.validate!(options, [
        :server,
        sources: default_sources(),
        work_directory: nil,
        bounds: nil,
        clock: &DateTime.utc_now/0,
        write_options: [],
        shard_bytes_max: @shard_bytes_max,
        download_bytes_max: @download_bytes_max,
        heap_words_max: @heap_words_max
      ])

    started_ms = System.monotonic_time(:millisecond)
    now = Keyword.fetch!(options, :clock).()
    work_directory = work_directory(options)
    File.mkdir_p!(work_directory)

    try do
      outcome = fetch_and_build(options, %{now: now, work_directory: work_directory})
      finish(outcome, %{started_ms: started_ms, options: options})
    after
      File.rm_rf!(work_directory)
    end
  end

  defp work_directory(options) do
    case Keyword.fetch!(options, :work_directory) do
      nil ->
        Path.join(System.tmp_dir!(), "gobusgo-addresses-#{System.unique_integer([:positive])}")

      directory ->
        directory
    end
  end

  defp default_sources do
    [
      {Gobusgo.Addresses.Source.King, []},
      {Gobusgo.Addresses.Source.Pierce, []},
      {Gobusgo.Addresses.Source.Snohomish, []}
    ]
  end

  defp fetch_and_build(options, %{now: now, work_directory: work_directory}) do
    sources = Keyword.fetch!(options, :sources)
    bytes_max = Keyword.fetch!(options, :download_bytes_max)

    case fetch_all(sources, %{work_directory: work_directory, bytes_max: bytes_max}) do
      {:ok, fetched} ->
        build_in_process(%{
          options: options,
          now: now,
          fetched: fetched,
          bounds: bounds(options),
          current: Addresses.built(Keyword.fetch!(options, :server))
        })

      {:stale, _details} = stale ->
        stale

      {:failed, _reason} = failed ->
        failed
    end
  end

  # Each source writes into a directory of its own, so two sources that name
  # their file alike cannot overwrite one another.
  defp fetch_all(sources, %{work_directory: work_directory, bytes_max: bytes_max}) do
    sources
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, []}, fn {{source, source_options}, index}, {:ok, fetched} ->
      directory = Path.join(work_directory, "source-#{index}")
      File.mkdir_p!(directory)
      started_ms = System.monotonic_time(:millisecond)

      case source.fetch(%{directory: directory, bytes_max: bytes_max}, source_options) do
        {:ok, export} ->
          entry = %{
            module: source,
            name: source.name(),
            export: export,
            fetch_ms: System.monotonic_time(:millisecond) - started_ms
          }

          {:cont, {:ok, [entry | fetched]}}

        {:stale, details} ->
          {:halt, {:stale, Map.put(details, :source, source.name())}}

        {:error, reason} ->
          {:halt, {:failed, {:fetch, source.name(), reason}}}
      end
    end)
    |> reversed()
  end

  defp reversed({:ok, fetched}), do: {:ok, Enum.reverse(fetched)}
  defp reversed(other), do: other

  defp bounds(options) do
    case Keyword.fetch!(options, :bounds) do
      nil -> basemap_bounds()
      override -> override
    end
  end

  # The union of the archives' bounds: the area a map page can show.
  defp basemap_bounds do
    with {:ok, %{dir: dir}} <- Gobusgo.Config.basemap(),
         {:ok, %{archives: archives}} <- Gobusgo.Basemap.read_manifest(dir) do
      all = Enum.map(archives, & &1.bounds)

      {:bounds,
       %{
         south: all |> Enum.map(& &1.south) |> Enum.min(),
         west: all |> Enum.map(& &1.west) |> Enum.min(),
         north: all |> Enum.map(& &1.north) |> Enum.max(),
         east: all |> Enum.map(& &1.east) |> Enum.max()
       }}
    else
      _no_basemap -> :none
    end
  end

  # The build runs in a process of its own, under a heap cap and a full
  # sweep at every collection. The process is linked, so it dies with a run
  # that is killed; the run traps exits while it waits, so the kill of the
  # process reaches it as a message, and any other exit is raised again.
  # While it waits the run samples the process's heap, which is how the peak
  # is known.
  defp build_in_process(input) do
    heap_words_max = Keyword.fetch!(input.options, :heap_words_max)
    Assert.condition(is_integer(heap_words_max), "heap_words_max must be an integer")

    Assert.condition(
      heap_words_max > 0,
      "heap_words_max must be positive, got: #{heap_words_max}"
    )

    parent = self()
    tag = make_ref()
    trapping = Process.flag(:trap_exit, true)

    {pid, monitor} =
      :erlang.spawn_opt(fn -> send(parent, {tag, build(input)}) end, [
        :link,
        :monitor,
        fullsweep_after: 0,
        max_heap_size: %{size: heap_words_max, kill: true, error_logger: true}
      ])

    {result, heap_words_peak} = await(%{tag: tag, pid: pid, monitor: monitor, peak: 0})
    Process.demonitor(monitor, [:flush])

    receive do
      {:EXIT, ^pid, _reason} -> :ok
    end

    Process.flag(:trap_exit, trapping)

    case result do
      {:ok, outcome} -> annotate(outcome, %{heap_words_peak: heap_words_peak})
      {:exit, :killed} -> {:killed, %{heap_words_max: heap_words_max}}
      {:exit, reason} -> exit(reason)
    end
  end

  defp await(%{tag: tag, pid: pid, monitor: monitor, peak: peak} = state) do
    receive do
      {^tag, outcome} -> {{:ok, outcome}, peak}
      {:DOWN, ^monitor, :process, ^pid, reason} -> {{:exit, reason}, peak}
    after
      @sample_interval_ms ->
        await(%{state | peak: max(peak, heap_words(pid))})
    end
  end

  defp heap_words(pid) do
    case Process.info(pid, :total_heap_size) do
      {:total_heap_size, words} -> words
      nil -> 0
    end
  end

  defp annotate({kind, details}, extra) when kind in [:built, :unchanged],
    do: {kind, Map.merge(details, extra)}

  defp annotate(other, _extra), do: other

  defp build(input) do
    %{fetched: fetched, bounds: bounds, current: current} = input
    build_started_ms = System.monotonic_time(:millisecond)

    case read_all(fetched, Accumulator.new(bounds_value(bounds))) do
      {:ok, accumulator, sources} ->
        result = Accumulator.finish(accumulator)
        read_ms = System.monotonic_time(:millisecond) - build_started_ms
        today = DateTime.to_date(input.now)

        summary = %{
          counts: result.counts,
          street_count: length(result.streets),
          address_count: result.address_count,
          sources: sources,
          export_byte_count: sources |> Enum.map(& &1.export_byte_count) |> Enum.sum(),
          fetch_ms: sources |> Enum.map(& &1.fetch_ms) |> Enum.sum(),
          read_ms: read_ms
        }

        if unchanged?(current, %{sha256: result.sha256, today: today}) do
          {:unchanged, summary}
        else
          write_files(
            Map.merge(input, %{
              result: result,
              summary: summary,
              build_started_ms: build_started_ms
            })
          )
        end

      {:failed, _reason} = failed ->
        failed
    end
  end

  # The sources are read one after another into one accumulator, and a
  # source's file is deleted once it is read, so the disk holds at most the
  # files not yet read.
  defp read_all(fetched, accumulator) do
    Enum.reduce_while(fetched, {:ok, accumulator, []}, fn entry, {:ok, accumulator, sources} ->
      case read_source(entry, accumulator) do
        {:ok, accumulator, summary} -> {:cont, {:ok, accumulator, sources ++ [summary]}}
        {:failed, _reason} = failed -> {:halt, failed}
      end
    end)
  end

  defp read_source(%{module: source, name: name, export: export} = entry, accumulator) do
    started_ms = System.monotonic_time(:millisecond)
    counts_before = Accumulator.counts(accumulator)

    accumulator =
      export.path
      |> source.records()
      |> Enum.reduce(accumulator, &Accumulator.add(&2, &1))

    File.rm!(export.path)

    counts =
      Map.new(Accumulator.counts(accumulator), fn {cause, count} ->
        {cause, count - Map.fetch!(counts_before, cause)}
      end)

    if counts.read == export.record_count do
      summary = %{
        name: name,
        counts: counts,
        last_edit_at: export.last_edit_at,
        record_count: export.record_count,
        export_byte_count: export.byte_count,
        fetch_ms: entry.fetch_ms,
        read_ms: System.monotonic_time(:millisecond) - started_ms
      }

      {:ok, accumulator, summary}
    else
      {:failed, {:record_count_differs, name, counts.read, export.record_count}}
    end
  end

  defp bounds_value({:bounds, bounds}), do: bounds
  defp bounds_value(:none), do: nil

  defp unchanged?({:ok, %{inputs_sha256: sha256, built_on: today}}, %{
         sha256: sha256,
         today: today
       }), do: true

  defp unchanged?(_current, _candidate), do: false

  defp write_files(%{options: options, result: result, now: now} = input) do
    write_options = Keyword.fetch!(options, :write_options)
    directory = "#{Addresses.prefix()}/dt=#{now |> DateTime.to_date() |> Date.to_iso8601()}"

    shards =
      Shards.split(result.streets, %{
        encode: &Format.encode_shard/1,
        bytes_min: &Format.shard_bytes_min/1,
        bytes_max: Keyword.fetch!(options, :shard_bytes_max)
      })

    shard_files = Enum.map(shards, &shard_file(%{directory: directory, shard: &1}))
    entries = Enum.map(shard_files, & &1.entry)
    index_file = index_file(%{directory: directory, entries: entries})
    files = shard_files ++ [index_file]

    with :ok <- write_all(files, write_options),
         manifest = manifest(%{input: input, files: shard_files, index: index_file}),
         :ok <-
           write_manifest(manifest, %{
             directory: directory,
             now: now,
             write_options: write_options
           }) do
      :ok = Addresses.record(Keyword.fetch!(options, :server), manifest.record)

      {:built,
       Map.merge(input.summary, %{
         shard_count: length(shards),
         written_byte_count: files |> Enum.map(& &1.stored.byte_size) |> Enum.sum(),
         write_ms:
           System.monotonic_time(:millisecond) - input.build_started_ms - input.summary.read_ms
       })}
    else
      {:error, reason} -> {:failed, {:write, reason}}
    end
  end

  defp shard_file(%{directory: directory, shard: shard}) do
    content = Format.assert_expanded_size(:shard, shard.content)
    file = file(%{kind: Format.shard_kind(), directory: directory, content: content})

    Map.put(file, :entry, %{
      prefix: shard.prefix,
      name: Path.basename(file.destination),
      byte_size: file.stored.byte_size,
      sha256: file.stored.sha256
    })
  end

  defp index_file(%{directory: directory, entries: entries}) do
    file(%{
      kind: Format.index_kind(),
      directory: directory,
      content: Format.encode_index(entries)
    })
  end

  # The writer compresses the content of a destination ending in the
  # compression suffix with `Gobusgo.Compression.compress/1`, which gives
  # the same stream for the same content, so the stream hashed here is the
  # one stored.
  defp file(%{kind: kind, directory: directory, content: content}) do
    stored = Packed.stored(content)
    destination = Packed.destination(%{directory: directory, kind: kind, stored: stored})

    Assert.condition(
      Compression.compressed?(destination),
      "a file name ends in #{Compression.suffix()}"
    )

    %{destination: destination, content: content, stored: stored}
  end

  defp write_all(files, write_options) do
    Enum.reduce_while(files, :ok, fn file, :ok ->
      request = %{
        destination: file.destination,
        content: file.content,
        reader_keep_seconds: Addresses.reader_keep_seconds()
      }

      case Writer.write(request, write_options) do
        :ok -> {:cont, :ok}
        {:error, :already_exists} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp manifest(%{input: input, files: shard_files, index: index_file}) do
    built_at = input.now
    inputs_sha256 = input.result.sha256

    body = %{
      "builtAt" => DateTime.to_iso8601(built_at),
      "sourceLastEditAt" => DateTime.to_iso8601(newest_last_edit_at(input.summary.sources)),
      "inputsSha256" => Base.encode16(inputs_sha256, case: :lower),
      "addressCount" => input.result.address_count,
      "streetCount" => length(input.result.streets),
      "sources" => Enum.map(input.summary.sources, &source_entry/1),
      "index" => file_entry(index_file),
      "shards" => Enum.map(shard_files, &Map.put(file_entry(&1), "prefix", &1.entry.prefix))
    }

    %{
      body: body,
      record: %{manifest: body, inputs_sha256: inputs_sha256, built_at: built_at}
    }
  end

  defp newest_last_edit_at(sources) do
    sources |> Enum.map(& &1.last_edit_at) |> Enum.max(DateTime)
  end

  defp source_entry(source) do
    %{
      "name" => Atom.to_string(source.name),
      "lastEditAt" => DateTime.to_iso8601(source.last_edit_at),
      "recordCount" => source.record_count
    }
  end

  defp file_entry(%{destination: destination, stored: stored}),
    do: Packed.file_entry("/" <> destination, stored)

  defp write_manifest(manifest, %{directory: directory, now: now, write_options: write_options}) do
    destination =
      Addresses.manifest_destination(%{
        directory: directory,
        built_at: now,
        inputs_sha256: manifest.record.inputs_sha256
      })

    case Writer.write(
           %{
             destination: destination,
             content: CanonicalJson.encode(manifest.body),
             reader_keep_seconds: Addresses.reader_keep_seconds()
           },
           write_options
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp finish({:built, details}, %{started_ms: started_ms}) do
    Logger.info("Address shards built", log_properties(details, started_ms))
    {:ok, %{outcome: :built}}
  end

  defp finish({:unchanged, details}, %{started_ms: started_ms}) do
    Logger.info("Address shards unchanged", log_properties(details, started_ms))
    {:ok, %{outcome: :unchanged}}
  end

  defp finish({:stale, details}, %{started_ms: started_ms}) do
    Logger.warning(
      "Address export stale",
      reason: details.reason,
      source: details.source,
      layer_last_edit_at: DateTime.to_iso8601(details.layer_last_edit_at),
      layer_record_count: details.layer_record_count,
      elapsed_ms: System.monotonic_time(:millisecond) - started_ms
    )

    {:ok, %{outcome: :stale}}
  end

  defp finish({:killed, details}, _context) do
    Logger.error("Address shard build killed", heap_words_max: details.heap_words_max)
    {:error, :killed}
  end

  defp finish({:failed, reason}, %{started_ms: started_ms}) do
    Logger.error("Address shards not built",
      reason: inspect(reason),
      elapsed_ms: System.monotonic_time(:millisecond) - started_ms
    )

    {:error, reason}
  end

  defp log_properties(details, started_ms) do
    counts = details.counts

    [
      read_count: counts.read,
      accepted_count: counts.accepted,
      invalid_count: counts.invalid,
      suffix_unsupported_count: counts.suffix_unsupported,
      outside_bounds_count: counts.outside_bounds,
      inactive_count: counts.inactive,
      street_count: details.street_count,
      address_count: details.address_count,
      shard_count: Map.get(details, :shard_count, 0),
      written_byte_count: Map.get(details, :written_byte_count, 0),
      export_byte_count: details.export_byte_count,
      fetch_ms: details.fetch_ms,
      read_ms: details.read_ms,
      write_ms: Map.get(details, :write_ms, 0),
      heap_words_peak: details.heap_words_peak,
      elapsed_ms: System.monotonic_time(:millisecond) - started_ms
    ] ++ Enum.flat_map(details.sources, &source_properties/1)
  end

  # One set of properties for each source, named by the source, so the line
  # says how many records each county read and accepted and how long each
  # step of it took.
  defp source_properties(source) do
    name = source.name

    [
      {:"#{name}_read_count", source.counts.read},
      {:"#{name}_accepted_count", source.counts.accepted},
      {:"#{name}_fetch_ms", source.fetch_ms},
      {:"#{name}_read_ms", source.read_ms},
      {:"#{name}_export_byte_count", source.export_byte_count}
    ]
  end
end
