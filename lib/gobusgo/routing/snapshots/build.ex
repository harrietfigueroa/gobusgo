defmodule Gobusgo.Routing.Snapshots.Build do
  @moduledoc """
  One run of the routing snapshot build: for every service date the
  schedule view holds, builds the snapshot from that date's schedules and
  the previous date's, writes its files, and records its manifest entry.

  A date is passed over when the SHA-256 of its inputs, the request
  identifiers of both dates' schedules and the positions of the stop view's
  stops, is that of its current entry and the entry was built today. A file
  whose destination already exists holds the same content, since its name
  is the content's hash, and counts as written. A date whose files are not
  all written keeps the entry it had. Entries of dates the view no longer
  holds are dropped.

  ## Logs

  One line per run that builds or fails: `Routing snapshots built` at
  `info`, or `Routing snapshots not built` at `error` when a date's files
  were not written, with the counts built, passed over, and failed, the
  connection count of the dates built, and the time taken. A run that
  builds nothing and fails nothing logs `debug`.

  ## Options

    * `:server` (required): the `Gobusgo.Routing.Snapshots` process.
    * `:schedule_view` and `:stop_view`: the views read. Default to
      `Gobusgo.OneBusAway.RouteScheduleView` and
      `Gobusgo.OneBusAway.StopView`.
    * `:clock`: returns the current UTC time. Defaults to
      `DateTime.utc_now/0`.
    * `:write_options`: options for `Gobusgo.Writer.write/2`.
  """

  require Logger

  alias Gobusgo.OneBusAway.RouteScheduleView
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.Routing.Snapshot
  alias Gobusgo.Routing.Snapshots
  alias Gobusgo.Routing.Timetable
  alias Gobusgo.Routing.Transfers
  alias Gobusgo.Writer

  @type counts :: %{
          built_count: non_neg_integer(),
          unchanged_count: non_neg_integer(),
          failed_count: non_neg_integer(),
          connection_count: non_neg_integer()
        }

  @doc "Builds the snapshot of every held service date whose inputs changed."
  @spec run(Keyword.t()) :: {:ok, counts()} | {:error, counts()}
  def run(options) when is_list(options) do
    options =
      Keyword.validate!(options, [
        :server,
        schedule_view: RouteScheduleView,
        stop_view: StopView,
        clock: &DateTime.utc_now/0,
        write_options: []
      ])

    started_ms = System.monotonic_time(:millisecond)
    server = Keyword.fetch!(options, :server)
    schedule_view = Keyword.fetch!(options, :schedule_view)
    now = Keyword.fetch!(options, :clock).()
    today = DateTime.to_date(now)
    dates = RouteScheduleView.held_dates(schedule_view)
    positions = positions(Keyword.fetch!(options, :stop_view))
    built = Snapshots.built(server)

    outcomes =
      for date <- dates do
        schedules = RouteScheduleView.schedules_on(schedule_view, date)
        previous = RouteScheduleView.schedules_on(schedule_view, Date.add(date, -1))
        inputs_sha256 = inputs_sha256(schedules, previous, positions)

        case Map.get(built, date) do
          %{inputs_sha256: ^inputs_sha256, built_on: ^today} ->
            :unchanged

          _other ->
            build_date(%{
              date: date,
              schedules: schedules,
              previous: previous,
              positions: positions,
              inputs_sha256: inputs_sha256,
              now: now,
              options: options
            })
        end
      end

    :ok = Snapshots.retain(server, dates)

    counts = %{
      built_count: Enum.count(outcomes, &match?({:built, _count}, &1)),
      unchanged_count: Enum.count(outcomes, &(&1 == :unchanged)),
      failed_count: Enum.count(outcomes, &(&1 == :failed)),
      connection_count: Enum.sum(for {:built, count} <- outcomes, do: count)
    }

    log(counts, System.monotonic_time(:millisecond) - started_ms)

    if counts.failed_count == 0, do: {:ok, counts}, else: {:error, counts}
  end

  defp positions(stop_view) do
    for %{id: id, stop: %{"lat" => lat, "lon" => lon}} <- StopView.current(stop_view),
        into: %{},
        do: {id, %{lat: lat, lon: lon}}
  end

  defp inputs_sha256(schedules, previous, positions) do
    requests =
      for fetch <- schedules ++ previous, do: {fetch.id, fetch.service_date, fetch.request_id}

    :crypto.hash(:sha256, :erlang.term_to_binary({Enum.sort(requests), Enum.sort(positions)}))
  end

  defp build_date(%{date: date, schedules: schedules, previous: previous, now: now} = input) do
    timetable =
      Timetable.build(%{
        service_date: date,
        schedules: Enum.map(schedules, & &1.schedule),
        previous_schedules: Enum.map(previous, & &1.schedule)
      })

    fetch_times = Enum.map(schedules ++ previous, & &1.fetched_at)

    %{files: files, entry: entry} =
      Snapshot.build(%{
        timetable: timetable,
        walking_links: Transfers.walking_links(timetable.stop_ids, input.positions),
        positions: input.positions,
        built_at: now,
        fetched_at_oldest: Enum.min(fetch_times, DateTime),
        fetched_at_newest: Enum.max(fetch_times, DateTime)
      })

    write_options = Keyword.fetch!(input.options, :write_options)

    if Enum.all?(files, &written?(&1, write_options)) do
      :ok =
        Snapshots.record(Keyword.fetch!(input.options, :server), %{
          service_date: date,
          entry: entry,
          inputs_sha256: input.inputs_sha256,
          built_on: DateTime.to_date(now)
        })

      {:built, length(timetable.connections)}
    else
      :failed
    end
  end

  defp written?(%{destination: destination, content: content}, write_options) do
    case Writer.write(%{destination: destination, content: content}, write_options) do
      :ok -> true
      {:error, :already_exists} -> true
      {:error, _reason} -> false
    end
  end

  defp log(counts, elapsed_ms) do
    properties = Map.to_list(counts) ++ [elapsed_ms: elapsed_ms]

    cond do
      counts.failed_count >= 1 -> Logger.error("Routing snapshots not built", properties)
      counts.built_count >= 1 -> Logger.info("Routing snapshots built", properties)
      true -> Logger.debug("Routing snapshots unchanged", properties)
    end
  end
end
