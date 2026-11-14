defmodule Mix.Tasks.Gobusgo.WalkGraph.Build do
  @shortdoc "Builds the walking paths of a Geofabrik extract"

  @moduledoc """
  Builds the walk graph a journey's walks are drawn along, from a Geofabrik
  Washington extract.

      mix gobusgo.walk_graph.build --extract PATH [--bounds SOUTH,WEST,NORTH,EAST] [--working-directory DIRECTORY]

    * `--extract`: the `.osm.pbf` extract
    * `--bounds`: the box the ways must touch; without it the union of the
      bounds of the archives in the basemap manifest of the data directory,
      and with neither the task refuses
    * `--working-directory`: where the osmium steps write their files, which
      are removed at the end; without it a temporary directory

  The task stores the shards, the index, and then the manifest under
  `intersections/` through the configured writer, as
  `Gobusgo.WalkGraph.Publication` describes, and prints where. It needs the
  `osmium` executable on the `PATH`, is run by hand and never on a start, and
  exits with a failure when a step fails. See `Gobusgo.WalkGraph.Build` for
  the steps and the counts it prints.
  """

  use Mix.Task

  alias Gobusgo.Basemap
  alias Gobusgo.Places.Bounds
  alias Gobusgo.WalkGraph.Build
  alias Gobusgo.WalkGraph.Publication

  @switches [extract: :string, bounds: :string, working_directory: :string]

  @impl Mix.Task
  def run(arguments) do
    options =
      case OptionParser.parse(arguments, strict: @switches) do
        {options, [], []} -> options
        {_options, _rest, _invalid} -> Mix.raise("see mix help gobusgo.walk_graph.build")
      end

    extract_path = fetch_option(options, :extract)

    # Loads the runtime configuration, which names the basemap directory.
    Mix.Task.run("app.config")

    request = %{
      extract_path: extract_path,
      bounds: bounds(options),
      working_dir: Keyword.get(options, :working_directory)
    }

    case Build.run(request, []) do
      {:ok, result} ->
        report(result)
        publish(result)

      {:error, reason} ->
        Mix.raise("walk graph build failed: #{inspect(reason)}")
    end
  end

  defp bounds(options) do
    case Keyword.fetch(options, :bounds) do
      {:ok, text} -> parse_bounds(text)
      :error -> manifest_bounds()
    end
  end

  defp parse_bounds(text) do
    case Bounds.parse(text) do
      {:ok, bounds} ->
        bounds

      {:error, :invalid_bounds} ->
        Mix.raise("--bounds must be south,west,north,east, got: #{text}")
    end
  end

  defp manifest_bounds do
    {:ok, %{dir: dir}} = Gobusgo.Config.basemap()

    case Basemap.read_manifest(dir) do
      {:ok, manifest} ->
        Bounds.from_manifest(manifest)

      {:error, reason} ->
        Mix.raise("no --bounds and no basemap manifest in #{dir}: #{inspect(reason)}")
    end
  end

  defp report(result) do
    shell = Mix.shell()
    counts = result.selection

    for %{name: name, duration_ms: duration_ms} <- result.steps do
      shell.info("Step #{name}: #{duration_ms} ms")
    end

    shell.info("Selection and cutting: #{result.select_ms} ms")
    shell.info("Source date: #{result.source_date}")

    shell.info(
      "Ways read #{counts.ways_read}, kept #{counts.ways_kept}, excluded #{inspect(counts.ways_excluded)}, " <>
        "missing nodes #{counts.ways_missing_nodes}, malformed lines #{counts.malformed_lines}"
    )

    shell.info(
      "Nodes #{counts.nodes}, junctions #{counts.junction_nodes}, pieces #{counts.pieces}, " <>
        "points #{counts.points}, tiles #{map_size(result.tiles)}"
    )
  end

  defp publish(result) do
    request = %{
      source_date: result.source_date,
      tiles: result.tiles,
      built_at: DateTime.truncate(DateTime.utc_now(), :second)
    }

    case Publication.publish(request, []) do
      {:ok, published} ->
        shell = Mix.shell()
        sizes = Enum.sort(published.shard_byte_sizes)

        shell.info(
          "Stored #{published.shard_count} shards: gzip p50 #{percentile(sizes, 50)}, " <>
            "p90 #{percentile(sizes, 90)}, max #{List.last(sizes)}, " <>
            "index #{published.index_byte_size}, total #{published.byte_count} bytes"
        )

        shell.info("Stored #{published.manifest_destination} for build #{published.build_id}")

      {:error, reason} ->
        Mix.raise("walk graph publication failed: #{inspect(reason)}")
    end
  end

  # The nearest-rank percentile of a sorted list.
  defp percentile(sorted, percent) do
    rank = Float.ceil(percent * length(sorted) / 100)
    Enum.at(sorted, max(trunc(rank) - 1, 0))
  end

  defp fetch_option(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} -> value
      :error -> Mix.raise("missing --#{String.replace(Atom.to_string(name), "_", "-")}")
    end
  end
end
