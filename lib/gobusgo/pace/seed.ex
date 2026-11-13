defmodule Gobusgo.Pace.Seed do
  @discovery_page_count_max 1_000
  @node_default "seed"
  @date_count_max 31

  @moduledoc """
  Writes the daily pace aggregate of one UTC day from the stored
  `vehicles-for-agency` fetches of that day and the schedules, route
  stops, and route paths stored for the service dates they ran on, so that
  learned paces exist without waiting for ingestion to learn them. The
  rules are those of ingestion: each fetch goes through
  `Gobusgo.Pace.Observation`, the file is `Gobusgo.Pace.Aggregate`, written
  to the same destination under the node name `"#{@node_default}"` by
  default, which tells a seeded file from an ingested one.

  `run/1` lists `paces/daily/dt=<date>/` first and skips the date when any
  file is there, since a reader sums every file of a date and a second
  learning of the day would count it twice. It never deletes or overwrites.
  Otherwise it prepares the views the path source reads, by default
  `Gobusgo.OneBusAway.RouteRebuild` and
  `Gobusgo.OneBusAway.RouteScheduleRebuild` as of the end of the date, then
  reads the day's fetches one file at a time in the order the reader lists
  them, which is by agency and then by fetch time, so no more than one
  fetch is held at once. The vehicles and trip paths held are discarded
  where the agency changes, so a vehicle's chain never crosses agencies.

  Everything is bounded: discovery makes at most
  #{@discovery_page_count_max} calls of `Gobusgo.Reader.discovery_limit_max/0`
  destinations, the table holds at most `:cell_count_max` cells, and the
  step holds at most `:vehicle_count_max` vehicles and `:path_count_max`
  paths, the defaults of `Gobusgo.Pace`. A fetch that cannot be read or parsed is
  counted and the run goes on. A run is not live, so the paths one fetch may
  read are bounded only by `:path_build_count_max`, by default the vehicle
  bound.

  ## Logs

  One line per date written: `Pace table seeded` at `info`, or `Pace table
  seeded incomplete` at `warning` when a fetch failed, with the date, the
  count of fetches read and of those that failed, `cell_count`,
  `meters_total`, and `dropped_cell_count`. A path read that raises is
  logged once per date as `Pace paths not read` at `warning`, and a write
  that fails as `Pace table not written` at `error`.

  ## Options

    * `:date`: the UTC date, required.
    * `:read_options`: options of `Gobusgo.Reader`, for the fetches, the
      listing of the date's files, and the rebuilds.
    * `:write_options`: options of `Gobusgo.Writer`.
    * `:node`, `:file_id`, `:clock`, `:path_source`, `:views`,
      `:prepare_views`, and the bounds above replace the defaults;
      `:prepare_views` is a function of the date.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.OneBusAway.RawVehicleResponse
  alias Gobusgo.OneBusAway.RouteRebuild
  alias Gobusgo.OneBusAway.RouteScheduleRebuild
  alias Gobusgo.Pace.Aggregate
  alias Gobusgo.Pace.Learning
  alias Gobusgo.Pace.Observation
  alias Gobusgo.Pace.PathSource
  alias Gobusgo.Pace.Table
  alias Gobusgo.Reader
  alias Gobusgo.RequestId
  alias Gobusgo.Writer

  @type summary :: %{
          date: Date.t(),
          fetch_count: non_neg_integer(),
          failed_fetch_count: non_neg_integer(),
          cell_count: non_neg_integer(),
          meters_total: number(),
          dropped_cell_count: non_neg_integer()
        }

  @typedoc """
    * `{:written, summary}`: the date's file is stored.
    * `{:empty, summary}`: the fetches gave no cell, and no file is stored.
    * `{:skipped, :already_written}`: the date has a file already.
    * `{:error, reason}`: a listing failed, or the write did.
  """
  @type result ::
          {:written, summary()}
          | {:empty, summary()}
          | {:skipped, :already_written}
          | {:error, term()}

  @doc """
  The UTC dates from `request.from` to `request.to`, inclusive, one run of
  `run/1` each, or why the range is refused: `to` before `from`, or more
  than #{@date_count_max} dates.
  """
  @spec dates(%{from: Date.t(), to: Date.t()}) ::
          {:ok, [Date.t()]} | {:error, :range_reversed | :range_too_long}
  def dates(%{from: %Date{} = from, to: %Date{} = to}) do
    count = Date.diff(to, from) + 1

    case count do
      count when count < 1 -> {:error, :range_reversed}
      count when count > @date_count_max -> {:error, :range_too_long}
      count -> {:ok, Enum.map(0..(count - 1)//1, &Date.add(from, &1))}
    end
  end

  @doc "Seeds `options.date`; see the module's documentation."
  @spec run(Keyword.t()) :: result()
  def run(options) when is_list(options) do
    options =
      options
      |> Keyword.validate!([
        :date,
        read_options: [],
        write_options: [],
        node: @node_default,
        file_id: &RequestId.generate/0,
        clock: &DateTime.utc_now/0,
        views: %{
          schedule_view: Gobusgo.OneBusAway.RouteScheduleView,
          route_path_view: Gobusgo.OneBusAway.RoutePathView,
          stop_view: Gobusgo.OneBusAway.StopView
        },
        path_source: &PathSource.fetch/2,
        prepare_views: nil,
        cell_count_max: Table.cell_count_max_default(),
        vehicle_count_max: Observation.vehicle_count_max_default(),
        path_count_max: Observation.path_count_max_default(),
        path_build_count_max: nil
      ])
      |> Map.new()

    Assert.condition(match?(%Date{}, options.date), "date must be a Date")

    for key <- [:cell_count_max, :vehicle_count_max, :path_count_max] do
      value = Map.fetch!(options, key)
      Assert.condition(is_integer(value) and value >= 1, "#{key} must be a positive integer")
    end

    options = fill_defaults(options)

    case existing_file(options) do
      :none -> seed(options)
      :some -> {:skipped, :already_written}
      {:error, _reason} = failed -> failed
    end
  end

  defp fill_defaults(options) do
    build_count_max = options.path_build_count_max || options.vehicle_count_max
    prepare_views = options.prepare_views || (&prepare_views(&1, options.read_options))
    %{options | path_build_count_max: build_count_max, prepare_views: prepare_views}
  end

  defp existing_file(%{date: date, read_options: read_options}) do
    prefix = "#{Aggregate.prefix()}/dt=#{Date.to_iso8601(date)}/"
    request = %{prefix: prefix, limit: 1, order: :ascending, cursor: nil}

    case Reader.discover(request, read_options) do
      {:ok, %{destinations: []}} -> :none
      {:ok, %{destinations: [_file | _rest]}} -> :some
      {:error, :not_found} -> :none
      {:error, reason} -> {:error, {:existing_not_listed, reason}}
    end
  end

  # The rebuilds read the days the date's vehicles ran on: the route views
  # of the date and the day before, and the schedules of the service dates
  # around it.
  defp prepare_views(date, read_options) do
    now = fn -> DateTime.new!(date, ~T[23:59:00], "Etc/UTC") end
    RouteRebuild.run(now: now, read_options: read_options)
    RouteScheduleRebuild.run(now: now, read_options: read_options)
    :ok
  end

  defp seed(options) do
    options.prepare_views.(options.date)
    table = Table.new(%{date: options.date, cell_count_max: options.cell_count_max})

    start = %{
      step: Observation.new(table),
      agency_id: nil,
      fetch_count: 0,
      failed_fetch_count: 0,
      path_error: nil
    }

    case learn_pages(options, start) do
      {:ok, learned} -> finish(options, learned)
      {:error, _reason} = failed -> failed
    end
  end

  defp learn_pages(options, start) do
    prefix = "#{RawVehicleResponse.destination_prefix()}/dt=#{Date.to_iso8601(options.date)}/"
    first = {:more, nil, start}

    pages = 1..@discovery_page_count_max//1

    outcome =
      Enum.reduce_while(pages, first, fn _page, {:more, cursor, learned} ->
        request = %{
          prefix: prefix,
          limit: Reader.discovery_limit_max(),
          order: :ascending,
          cursor: cursor
        }

        case Reader.discover(request, options.read_options) do
          {:ok, %{destinations: destinations, cursor: next}} ->
            learned = Enum.reduce(destinations, learned, &learn_fetch(&1, &2, options))
            continue_or_halt(next, learned)

          {:error, reason} ->
            {:halt, {:error, {:fetches_not_listed, reason}}}
        end
      end)

    case outcome do
      {:done, learned} -> {:ok, learned}
      {:more, _cursor, _learned} -> {:error, :too_many_fetches}
      {:error, _reason} = failed -> failed
    end
  end

  defp continue_or_halt(nil, learned), do: {:halt, {:done, learned}}
  defp continue_or_halt(next, learned), do: {:cont, {:more, next, learned}}

  defp learn_fetch(destination, learned, options) do
    with {:ok, content} <- Reader.read(destination, options.read_options),
         {:ok, fetch} <- RawVehicleResponse.parse(%{destination: destination, content: content}) do
      learned = learned |> forget_other_agencies(fetch.agency_id) |> keep_path_error()
      reports = Learning.reports(fetch)
      step = Observation.learn(%{state: learned.step, reports: reports, options: options})

      %{learned | step: step, fetch_count: learned.fetch_count + 1}
    else
      {:error, _reason} -> %{learned | failed_fetch_count: learned.failed_fetch_count + 1}
    end
  end

  # A vehicle's chain stays in one agency, so what is held for the last
  # agency is of no use to the next.
  defp forget_other_agencies(%{agency_id: agency_id} = learned, agency_id), do: learned

  defp forget_other_agencies(%{step: step} = learned, agency_id) do
    step = %{step | vehicles: %{}, paths: %{}}
    %{learned | step: step, agency_id: agency_id}
  end

  defp keep_path_error(%{step: %{path_error: nil}} = learned), do: learned

  defp keep_path_error(%{step: step, path_error: held} = learned) do
    %{learned | step: %{step | path_error: nil}, path_error: held || step.path_error}
  end

  defp finish(options, %{step: step} = learned) do
    table = step.table
    path_error = learned.path_error || step.path_error

    if path_error != nil do
      Logger.warning("Pace paths not read", err: path_error)
    end

    summary = %{
      date: options.date,
      fetch_count: learned.fetch_count,
      failed_fetch_count: learned.failed_fetch_count,
      cell_count: map_size(table.cells),
      meters_total: Float.round(Table.meters_total(table) * 1.0, 3),
      dropped_cell_count: table.dropped_count
    }

    if summary.cell_count == 0 do
      log_seeded(summary)
      {:empty, summary}
    else
      store(table, summary, options)
    end
  end

  defp store(table, summary, options) do
    file =
      Aggregate.build(%{
        table: table,
        node: options.node,
        file_id: options.file_id.(),
        written_at: options.clock.()
      })

    request = %{destination: file.destination, content: file.content}

    case Writer.write(request, options.write_options) do
      :ok ->
        log_seeded(summary)
        {:written, summary}

      {:error, reason} ->
        Logger.error("Pace table not written",
          date: Date.to_iso8601(summary.date),
          cell_count: summary.cell_count,
          reason: inspect(reason)
        )

        {:error, {:not_written, reason}}
    end
  end

  defp log_seeded(%{failed_fetch_count: 0} = summary) do
    Logger.info("Pace table seeded", properties(summary))
  end

  defp log_seeded(summary) do
    Logger.warning("Pace table seeded incomplete", properties(summary))
  end

  defp properties(summary) do
    [
      date: Date.to_iso8601(summary.date),
      fetch_count: summary.fetch_count,
      failed_fetch_count: summary.failed_fetch_count,
      cell_count: summary.cell_count,
      meters_total: summary.meters_total,
      dropped_cell_count: summary.dropped_cell_count
    ]
  end
end
