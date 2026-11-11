defmodule Mix.Tasks.Gobusgo.Intersections.Build do
  @shortdoc "Builds the street intersections of a Geofabrik extract"

  @moduledoc """
  Builds the intersections a map search finds, from a Geofabrik Washington
  extract.

      mix gobusgo.intersections.build --extract PATH [--bounds SOUTH,WEST,NORTH,EAST] [--working-directory DIRECTORY]

    * `--extract`: the `.osm.pbf` extract
    * `--bounds`: the box the intersections must lie in; without it the union
      of the bounds of the archives in the basemap manifest of the data
      directory, and with neither the task refuses
    * `--working-directory`: where the osmium steps write their files, which
      are removed at the end; without it a temporary directory

  The task stores the shards, the index, and then the manifest under
  `intersections/` through the configured writer, as
  `Gobusgo.Intersections.Publication` describes, and prints where. It needs
  the `osmium` executable on the `PATH`, is run by hand and never on a
  start, and exits with a failure when a step fails. See
  `Gobusgo.Intersections.Build` for the steps and the counts it prints.
  """

  use Mix.Task

  alias Gobusgo.Basemap
  alias Gobusgo.Intersections.Build
  alias Gobusgo.Intersections.Classification
  alias Gobusgo.Intersections.Publication
  alias Gobusgo.Places.Bounds

  @switches [extract: :string, bounds: :string, working_directory: :string]

  @impl Mix.Task
  def run(arguments) do
    options =
      case OptionParser.parse(arguments, strict: @switches) do
        {options, [], []} -> options
        {_options, _rest, _invalid} -> Mix.raise("see mix help gobusgo.intersections.build")
      end

    extract_path = fetch_option(options, :extract)

    # Loads the runtime configuration, which names the basemap directory.
    Mix.Task.run("app.config")
    bounds = bounds(options)

    request = %{
      extract_path: extract_path,
      bounds: bounds,
      working_dir: Keyword.get(options, :working_directory),
      service_roads: Classification.service_roads()
    }

    case Build.run(request, []) do
      {:ok, result} ->
        report(result)
        publish(result)

      {:error, reason} ->
        Mix.raise("intersections build failed: #{inspect(reason)}")
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

    shell.info("Selection, merge, and grouping: #{result.select_ms} ms")
    shell.info("Source date: #{result.source_date}")

    shell.info(
      "Ways read #{counts.ways_read}, wrong class #{counts.ways_wrong_class}, unnamed #{counts.ways_unnamed}, " <>
        "unsupported name #{counts.ways_unsupported_name}, kept #{counts.ways_kept}"
    )

    shell.info(
      "Road nodes #{counts.road_nodes}, shared #{counts.shared_nodes}, crowded #{counts.crowded_nodes}, " <>
        "outside #{counts.outside_nodes}, malformed lines #{counts.malformed_lines}"
    )

    shell.info(
      "Pairs #{result.pair_count}, intersections #{result.intersection_count}, streets #{length(result.streets)}"
    )
  end

  defp publish(result) do
    request = %{
      source_date: result.source_date,
      streets: result.streets,
      intersection_count: result.intersection_count,
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

        shell.info("Stored #{published.manifest_destination}")

      {:error, reason} ->
        Mix.raise("intersections publication failed: #{inspect(reason)}")
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
