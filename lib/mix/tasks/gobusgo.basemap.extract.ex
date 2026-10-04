defmodule Mix.Tasks.Gobusgo.Basemap.Extract do
  @shortdoc "Extracts the regional basemap archives of a stored agency response"

  @moduledoc """
  Extracts the regional basemap archives that the agencies of one stored
  agency response need, from one Protomaps daily build.

      mix gobusgo.basemap.extract --response DESTINATION --snapshot YYYYMMDD --output-dir DIRECTORY

    * `--response`: the logical destination of a stored `agencies-with-coverage`
      response, read through the configured reader
    * `--snapshot`: the date of the Protomaps build to cut from
    * `--output-dir`: the directory the archives and `manifest.json` go to

  Every option is required. The task needs the `pmtiles` executable on the
  `PATH`, does not start the application, and exits with a failure when the
  extraction fails. See `Gobusgo.Basemap.Extractor` for the results.
  """

  use Mix.Task

  alias Gobusgo.Basemap.Extractor

  @switches [response: :string, snapshot: :string, output_dir: :string]

  @impl Mix.Task
  def run(arguments) do
    request =
      case OptionParser.parse(arguments, strict: @switches) do
        {[_first, _second, _third] = options, [], []} ->
          %{
            response_destination: fetch_option(options, :response),
            snapshot: fetch_option(options, :snapshot),
            output_dir: fetch_option(options, :output_dir)
          }

        {_options, _rest, _invalid} ->
          Mix.raise(
            "expected exactly --response, --snapshot, and --output-dir; see mix help gobusgo.basemap.extract"
          )
      end

    # Loads the runtime configuration, which names the reader's backend.
    Mix.Task.run("app.config")

    case Extractor.run(request, []) do
      {:ok, %{archives: archives, manifest_path: manifest_path, skipped: skipped}} ->
        for %{path: path, bytes: bytes} <- archives do
          Mix.shell().info("Extracted #{path} (#{bytes} bytes)")
        end

        for %{agency_id: agency_id, reason: reason} <- skipped do
          Mix.shell().info("Skipped agency #{agency_id}: #{inspect(reason)}")
        end

        Mix.shell().info("Wrote #{manifest_path}")

      {:error, reason} ->
        Mix.raise("basemap extraction failed: #{inspect(reason)}")
    end
  end

  defp fetch_option(options, name) do
    case Keyword.fetch(options, name) do
      {:ok, value} -> value
      :error -> Mix.raise("missing --#{String.replace(Atom.to_string(name), "_", "-")}")
    end
  end
end
