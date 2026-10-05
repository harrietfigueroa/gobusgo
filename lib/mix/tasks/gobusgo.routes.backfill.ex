defmodule Mix.Tasks.Gobusgo.Routes.Backfill do
  @shortdoc "Fetches every agency's routes and every route's paths once"

  @moduledoc """
  Fetches the routes of every agency and the stops and paths of every route
  once, one request a second, and records each response: stored through the
  configured writer and announced through the configured publisher, the way
  a scheduled fetch is.

      mix gobusgo.routes.backfill [--agency ID]... [--route-limit COUNT]

    * `--agency`: an agency to backfill; give it once per agency. Without
      it, the task asks the server for the agencies.
    * `--route-limit`: the most routes to fetch the paths of. Without it,
      every route the agencies list, up to the limit of
      `Gobusgo.OneBusAway.RouteBackfill`.

  The task reads `ONEBUSAWAY_BASE_URL` and `ONEBUSAWAY_API_KEY`, the data
  directory, and the Kafka settings as the application does. It does not
  start the application: a running application consumes the events and
  fills its route views. The task prints one summary and exits with a
  failure when no response is recorded. See
  `Gobusgo.OneBusAway.RouteBackfill` for the bounds and the summary.
  """

  use Mix.Task

  alias Gobusgo.Config
  alias Gobusgo.Kafka
  alias Gobusgo.OneBusAway.RequestGate
  alias Gobusgo.OneBusAway.RouteBackfill

  @switches [agency: :keep, route_limit: :integer]

  @impl Mix.Task
  def run(arguments) do
    backfill_options =
      case OptionParser.parse(arguments, strict: @switches) do
        {options, [], []} -> backfill_options(options)
        {_options, _rest, _invalid} -> Mix.raise("see mix help gobusgo.routes.backfill")
      end

    # Loads the runtime configuration, which holds the OneBusAway settings
    # and names the writer's, the reader's, and the publisher's backends.
    Mix.Task.run("app.config")

    # The summary is the task's output; the libraries' connection lines at
    # lower levels would bury it.
    Logger.configure(level: :warning)
    {:ok, _started} = Application.ensure_all_started(:req)

    settings =
      case Config.one_bus_away() do
        {:ok, settings} -> settings
        {:error, {:missing, key}} -> Mix.raise("the OneBusAway setting #{key} is missing")
      end

    start_publisher()
    {:ok, _gate} = RequestGate.start_link(name: RequestGate)

    case RouteBackfill.run(settings, backfill_options) do
      {:ok, summary} ->
        Mix.shell().info(RouteBackfill.report(summary))

        if summary.recorded_count == 0 and summary.failed_count >= 1 do
          Mix.raise("route backfill recorded nothing")
        end

      {:error, {:agencies, reason}} ->
        Mix.raise("route backfill could not fetch the agencies: #{inspect(reason)}")
    end
  end

  defp backfill_options(options) do
    agency_ids = Keyword.get_values(options, :agency)

    case Keyword.fetch(options, :route_limit) do
      {:ok, limit} when limit >= 1 -> [route_count_max: limit]
      {:ok, limit} -> Mix.raise("--route-limit must be positive, got: #{limit}")
      :error -> []
    end ++
      case agency_ids do
        [] -> []
        [_first | _rest] -> [agency_ids: agency_ids]
      end
  end

  defp start_publisher do
    case Config.kafka() do
      {:ok, %{enabled: true, endpoints: endpoints}} ->
        {:ok, _started} = Application.ensure_all_started(:brod)
        :ok = Kafka.Client.start(%{client: Kafka.Client, endpoints: endpoints})

      {:ok, %{enabled: false}} ->
        :ok

      {:error, {_kind, key}} ->
        Mix.raise("the Kafka setting #{key} is not valid")
    end
  end
end
