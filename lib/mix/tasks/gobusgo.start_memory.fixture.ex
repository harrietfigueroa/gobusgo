defmodule Mix.Tasks.Gobusgo.StartMemory.Fixture do
  @shortdoc "Writes the synthetic stored responses the start-memory check runs against"

  @moduledoc """
  Writes the stored responses of `Gobusgo.StartMemory.Fixture` under
  `<directory>/raw/`, through the local file writer, as the recorders of a
  start fetched on the UTC date `--date` would have stored them, by default
  today's. The same date writes the same files.

      mix gobusgo.start_memory.fixture <directory> [--date YYYY-MM-DD] [--walk-graph]

  With `--walk-graph` the task also publishes the synthetic walk graph of
  `Gobusgo.StartMemory.WalkGraph` under `<directory>/intersections/`, where a
  start that measures its walks along the streets reads it.

  The directory must hold no `raw/` yet. The task does not start the
  application.
  """

  use Mix.Task

  alias Gobusgo.Deleter
  alias Gobusgo.Reader
  alias Gobusgo.StartMemory.Fixture
  alias Gobusgo.StartMemory.WalkGraph
  alias Gobusgo.WalkGraph.Publication
  alias Gobusgo.Writer

  @impl Mix.Task
  def run(arguments) do
    {options, positional} =
      OptionParser.parse!(arguments, strict: [date: :string, walk_graph: :boolean])

    directory =
      case positional do
        [directory] ->
          Path.expand(directory)

        _other ->
          Mix.raise("Usage: mix gobusgo.start_memory.fixture <directory> [--date YYYY-MM-DD]")
      end

    date = date(options)
    raw = Path.join(directory, "raw")

    if File.exists?(raw) do
      Mix.raise("#{raw} exists; the fixture is written into a directory that holds no raw/")
    end

    summary = Fixture.summary(date)
    count = date |> Fixture.responses() |> Enum.reduce(0, &write(&1, &2, directory))
    Mix.shell().info("Wrote #{count} responses fetched on #{date} under #{raw}")

    for schedule <- summary.schedules do
      Mix.shell().info(
        "  #{schedule.service_date}: #{schedule.route_count} schedules, #{schedule.trip_count} trips, #{schedule.connection_count} connections of its own trips"
      )
    end

    Mix.shell().info("  #{summary.route_count} route paths over #{summary.stop_count} stops")

    if Keyword.get(options, :walk_graph, false) do
      publish_walk_graph(directory)
    end
  end

  defp publish_walk_graph(directory) do
    summary = WalkGraph.summary()

    options = [
      read_options: [backend: Reader.LocalFile, base_dir: directory],
      write_options: [backend: Writer.LocalFile, base_dir: directory],
      delete_options: [backend: Deleter.LocalFile, base_dir: directory]
    ]

    case Publication.publish(WalkGraph.publication_request(), options) do
      {:ok, published} ->
        Mix.shell().info(
          "Published a walk graph of #{summary.tile_count} tiles and #{summary.piece_count} pieces, #{summary.window_piece_count_max} in the largest window and #{summary.band_piece_count_max} in the largest three rows, as build #{published.build_id}"
        )

      {:error, reason} ->
        Mix.raise("The walk graph was not published: #{inspect(reason)}")
    end
  end

  defp date(options) do
    case Keyword.fetch(options, :date) do
      {:ok, text} ->
        case Date.from_iso8601(text) do
          {:ok, date} -> date
          {:error, _reason} -> Mix.raise("--date must be a date such as 2026-11-08, got: #{text}")
        end

      :error ->
        Date.utc_today()
    end
  end

  defp write(%{destination: destination, content: content}, count, directory) do
    request = %{destination: destination, content: content}

    case Writer.write(request, backend: Writer.LocalFile, base_dir: directory) do
      :ok -> count + 1
      {:error, reason} -> Mix.raise("#{destination} not written: #{inspect(reason)}")
    end
  end
end
