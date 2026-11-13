defmodule Mix.Tasks.Gobusgo.Pace.Seed do
  @shortdoc "Writes daily pace aggregates from the stored vehicle fetches"

  @moduledoc """
  Writes the daily pace aggregate of each UTC day from the stored
  `vehicles-for-agency` fetches of that day, so learned paces exist without
  waiting for ingestion.

      mix gobusgo.pace.seed --date YYYY-MM-DD [--to YYYY-MM-DD]

    * `--date`: the first UTC day, the `dt=` partition of the fetches
    * `--to`: the last UTC day; without it only `--date`. A range is at most
      31 days.

  The task reads and writes through the configured reader and writer, so the
  same command runs against local files or a bucket by configuration. A day
  that has a file under `paces/daily/dt=<date>/` is skipped and said so, so
  a reader that sums the files of a date never counts a day twice, and the
  task deletes and overwrites nothing. It starts the application with the
  sources, the usage records, and the HTTP server off, so it makes no
  request of any provider. It is run by hand, a day at a time, and exits
  with a failure when a day's listing or write fails. See
  `Gobusgo.Pace.Seed` for the rules and the logs.
  """

  use Mix.Task

  alias Gobusgo.Pace.Seed

  @switches [date: :string, to: :string]

  @impl Mix.Task
  def run(arguments) do
    options =
      case OptionParser.parse(arguments, strict: @switches) do
        {options, [], []} -> options
        {_options, _rest, _invalid} -> Mix.raise("see mix help gobusgo.pace.seed")
      end

    from = date_option(options, :date)
    to = date_option(options, :to, from)

    dates =
      case Seed.dates(%{from: from, to: to}) do
        {:ok, dates} -> dates
        {:error, reason} -> Mix.raise("--to must be within 31 days after --date: #{reason}")
      end

    start_application()
    shell = Mix.shell()

    for date <- dates do
      report(shell, date, Seed.run(date: date))
    end

    :ok
  end

  defp date_option(options, key, default \\ nil) do
    case Keyword.fetch(options, key) do
      {:ok, text} -> parse_date(key, text)
      :error when is_struct(default, Date) -> default
      :error -> Mix.raise("--#{key} is required, see mix help gobusgo.pace.seed")
    end
  end

  defp parse_date(key, text) do
    case Date.from_iso8601(text) do
      {:ok, date} -> date
      {:error, _reason} -> Mix.raise("--#{key} must be YYYY-MM-DD, got: #{text}")
    end
  end

  # The settings are read first and the sources, the usage records, and the
  # HTTP server turned off after, so the views and the storage start and
  # nothing fetches or listens.
  defp start_application do
    Mix.Task.run("app.config")
    Application.put_env(:gobusgo, :ingestion, scheduled: false)
    Application.put_env(:gobusgo, :usage, recorded: false)
    endpoint = Application.get_env(:gobusgo, GobusgoWeb.Endpoint, [])
    Application.put_env(:gobusgo, GobusgoWeb.Endpoint, Keyword.put(endpoint, :server, false))
    Mix.Task.run("app.start")
  end

  defp report(shell, date, {:written, summary}) do
    shell.info("#{date}: wrote #{summary_text(summary)}")
  end

  defp report(shell, date, {:empty, summary}) do
    shell.info("#{date}: wrote no file, #{summary_text(summary)}")
  end

  defp report(shell, date, {:skipped, :already_written}) do
    shell.info("#{date}: skipped, a file is already stored for the date")
  end

  defp report(_shell, date, {:error, reason}) do
    Mix.raise("#{date}: #{inspect(reason)}")
  end

  defp summary_text(summary) do
    "#{summary.cell_count} cells, #{summary.meters_total} meters, " <>
      "#{summary.fetch_count} fetches read, #{summary.failed_fetch_count} failed, " <>
      "#{summary.dropped_cell_count} cells dropped"
  end
end
