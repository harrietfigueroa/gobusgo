defmodule Mix.Tasks.Gobusgo.Places.Build do
  @shortdoc "Builds the places of a Geofabrik extract"

  @moduledoc """
  Builds the places a map search finds, from a Geofabrik Washington extract.

      mix gobusgo.places.build --extract PATH [--bounds SOUTH,WEST,NORTH,EAST] [--working-directory DIRECTORY] [--records-json PATH]

    * `--extract`: the `.osm.pbf` extract
    * `--bounds`: the box the places must lie in; without it the union of the
      bounds of the archives in the basemap manifest of the data directory,
      and with neither the task refuses
    * `--working-directory`: where the osmium steps write their files, which
      are removed at the end; without it a temporary directory
    * `--records-json`: also writes the places as JSON rows to this path

  The task stores the places file and then its manifest under `places/`
  through the configured writer, as `Gobusgo.Places.Publication` describes,
  and prints where. It needs the `osmium` executable on the `PATH`, is run by
  hand and never on a start, and exits with a failure when a step fails. See
  `Gobusgo.Places.Build` for the steps and the counts it prints.
  """

  use Mix.Task

  alias Gobusgo.Basemap
  alias Gobusgo.Places.Bounds
  alias Gobusgo.Places.Build
  alias Gobusgo.Places.Publication
  alias Gobusgo.Places.Records

  @switches [
    extract: :string,
    bounds: :string,
    working_directory: :string,
    records_json: :string
  ]

  @impl Mix.Task
  def run(arguments) do
    options =
      case OptionParser.parse(arguments, strict: @switches) do
        {options, [], []} -> options
        {_options, _rest, _invalid} -> Mix.raise("see mix help gobusgo.places.build")
      end

    extract_path = fetch_option(options, :extract)

    # Loads the runtime configuration, which names the basemap directory.
    Mix.Task.run("app.config")
    bounds = bounds(options)

    request = %{
      extract_path: extract_path,
      bounds: bounds,
      working_dir: Keyword.get(options, :working_directory)
    }

    case Build.run(request, []) do
      {:ok, result} ->
        report(result)
        write_records(result, Keyword.get(options, :records_json))
        publish(result)

      {:error, reason} ->
        Mix.raise("places build failed: #{inspect(reason)}")
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

    shell.info("Selection and merge: #{result.select_ms} ms")
    shell.info("Source date: #{result.source_date}")

    shell.info(
      "Read #{counts.read}, named #{counts.named}, stops #{counts.stops}, excluded #{counts.excluded}, " <>
        "outside #{counts.outside}, unusable #{counts.unusable}, selected #{counts.kept}, " <>
        "merged #{result.merged_count}, kept #{length(result.places)}"
    )

    final = Enum.frequencies_by(result.places, & &1.category)

    for {category, %{kept: kept, outside: outside}} <- Enum.sort(counts.by_category) do
      shell.info(
        "  #{category}: #{kept} selected, #{outside} outside, #{Map.get(final, category, 0)} kept"
      )
    end
  end

  defp publish(result) do
    request = %{
      source_date: result.source_date,
      places: result.places,
      built_at: DateTime.truncate(DateTime.utc_now(), :second)
    }

    case Publication.publish(request, []) do
      {:ok, published} ->
        shell = Mix.shell()

        shell.info(
          "Stored #{published.file_destination}: #{published.place_count} places, " <>
            "#{published.expanded_bytes} bytes expanded, #{published.byte_size} bytes gzipped"
        )

        shell.info("Stored #{published.manifest_destination}")

      {:error, reason} ->
        Mix.raise("places publication failed: #{inspect(reason)}")
    end
  end

  defp write_records(_result, nil), do: :ok

  defp write_records(result, path) do
    case File.write(path, Records.encode(result)) do
      :ok -> Mix.shell().info("Wrote #{path}")
      {:error, reason} -> Mix.raise("could not write #{path}: #{inspect(reason)}")
    end
  end

  defp fetch_option(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} -> value
      :error -> Mix.raise("missing --#{String.replace(Atom.to_string(name), "_", "-")}")
    end
  end
end
