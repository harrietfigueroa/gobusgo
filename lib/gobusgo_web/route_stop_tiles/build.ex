defmodule GobusgoWeb.RouteStopTiles.Build do
  @executable "tippecanoe"
  @tippecanoe_deadline_ms 60_000
  @archive_bytes_max 16 * 1024 * 1024
  @zoom_min 5
  @zoom_max 14

  @moduledoc """
  One run of the route and stop tile archive: reads what a map page draws
  with no filter from the views, and builds and stores an archive of it when
  it differs from what the current archive was built from.

  The lines are those of `GobusgoWeb.RouteLines` and the stops those of
  `GobusgoWeb.StopMarkers` that a drawn route serves, encoded by
  `GobusgoWeb.RouteStopTiles.Features`. tippecanoe reads them from two files
  of a working directory of their own, which the run removes, and writes the
  archive there, from zoom #{@zoom_min} to #{@zoom_max}, with its own limits
  on features and bytes per tile turned off, so that no feature is dropped.
  It has #{@tippecanoe_deadline_ms} ms. An archive is stored only when it
  is at most #{@archive_bytes_max} bytes.

  A run returns `{:ok, :empty}` while the views hold no line, `{:ok,
  :unchanged}` when the lines are those of the current archive, `{:ok,
  build}` for an archive it stored and made the current one, and `{:error,
  reason}` for one it did not, which leaves the current archive as it was.

  ## Logs

  One line per run that builds: `Route stop tiles built` at `info`, with the
  destination, the counts of routes, routes left out, and stops, the
  archive's bytes, and the time taken, or `Route stop tiles not built` at
  `error` with the `reason`. A run that builds nothing logs nothing.

  ## Options

    * `:server`: the `GobusgoWeb.RouteStopTiles` process, required.
    * `:executable`: the path of tippecanoe, by default the one on the path.
    * `:now`: a zero-arity function returning the time, by default
      `DateTime.utc_now/0`.
    * `:gather`: a zero-arity function returning what to build,
      `t:content/0`, by default a read of the views.
    * `:write_options`: options for `Gobusgo.Writer.write/2`.
  """

  require Logger

  alias Gobusgo.Assert
  alias Gobusgo.Command
  alias Gobusgo.OneBusAway.AgencyView
  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.StopView
  alias Gobusgo.Writer
  alias GobusgoWeb.RouteLines
  alias GobusgoWeb.RouteStopTiles
  alias GobusgoWeb.RouteStopTiles.Features
  alias GobusgoWeb.StopMarkers

  @route_view Gobusgo.OneBusAway.RouteView
  @route_path_view Gobusgo.OneBusAway.RoutePathView

  @typedoc """
  What an archive is built from: the version of every drawn line, the lines
  themselves, and each drawn stop's marker with the identifiers of its
  drawn routes.
  """
  @type content :: %{
          versions: RouteLines.versions(),
          lines: [RouteLines.line()],
          stops: [%{marker: StopMarkers.marker(), route_ids: [String.t(), ...]}]
        }

  @type build :: %{
          destination: String.t(),
          route_count: non_neg_integer(),
          route_skipped_count: non_neg_integer(),
          stop_count: non_neg_integer(),
          archive_bytes: non_neg_integer()
        }

  @type error ::
          :executable_missing
          | {:tippecanoe, Command.error()}
          | {:archive_too_large, pos_integer()}
          | {:file, atom()}
          | {:write, Writer.error_reason()}

  @doc "Runs one build, as the module documentation describes."
  @spec run(Keyword.t()) :: {:ok, :empty | :unchanged | build()} | {:error, error()}
  def run(options) when is_list(options) do
    server = Keyword.fetch!(options, :server)
    gather = Keyword.get(options, :gather, &gather/0)
    content = gather.()

    cond do
      content.versions == %{} ->
        {:ok, :empty}

      content.versions == RouteStopTiles.built_versions(server) ->
        {:ok, :unchanged}

      true ->
        build_logged(content, server, options)
    end
  end

  defp build_logged(content, server, options) do
    started_ms = System.monotonic_time(:millisecond)
    now = Keyword.get(options, :now, &DateTime.utc_now/0)
    destination = RouteStopTiles.destination(now.())

    case build(%{content: content, destination: destination}, options) do
      {:ok, build} ->
        :ok =
          RouteStopTiles.record(server, %{destination: destination, versions: content.versions})

        Logger.info(
          "Route stop tiles built",
          Map.to_list(build) ++ [duration_ms: System.monotonic_time(:millisecond) - started_ms]
        )

        {:ok, build}

      {:error, reason} ->
        Logger.error("Route stop tiles not built",
          destination: destination,
          reason: inspect(reason),
          duration_ms: System.monotonic_time(:millisecond) - started_ms
        )

        {:error, reason}
    end
  end

  defp build(%{content: content, destination: destination}, options) do
    with {:ok, executable} <- executable(options) do
      work_dir =
        Path.join(
          System.tmp_dir!(),
          "gobusgo-route-stop-tiles-#{System.unique_integer([:positive])}"
        )

      try do
        build_in(
          %{
            content: content,
            destination: destination,
            executable: executable,
            work_dir: work_dir
          },
          options
        )
      after
        File.rm_rf(work_dir)
      end
    end
  end

  defp build_in(%{content: content, destination: destination} = build, options) do
    %{routes: routes, skipped_count: skipped_count} = route_features(content.lines)
    stops = for stop <- content.stops, {:ok, feature} = Features.stop(stop), do: feature

    paths = %{
      routes: Path.join(build.work_dir, "routes.geojsonl"),
      stops: Path.join(build.work_dir, "stops.geojsonl"),
      archive: Path.join(build.work_dir, "archive.pmtiles")
    }

    with :ok <- file_result(File.mkdir_p(build.work_dir)),
         :ok <- file_result(File.write(paths.routes, lines(routes))),
         :ok <- file_result(File.write(paths.stops, lines(stops))),
         :ok <-
           tippecanoe(%{executable: build.executable, paths: paths, work_dir: build.work_dir}),
         {:ok, archive} <- read_archive(paths.archive),
         :ok <- write(%{destination: destination, content: archive}, options) do
      {:ok,
       %{
         destination: destination,
         route_count: length(routes),
         route_skipped_count: skipped_count,
         stop_count: length(stops),
         archive_bytes: byte_size(archive)
       }}
    end
  end

  # A route whose polylines do not decode is left out and counted, as is a
  # route with no polyline to draw.
  defp route_features(lines) do
    Enum.reduce(lines, %{routes: [], skipped_count: 0}, fn line, acc ->
      case Features.route(line) do
        {:ok, feature} -> %{acc | routes: [feature | acc.routes]}
        _no_feature -> %{acc | skipped_count: acc.skipped_count + 1}
      end
    end)
    |> Map.update!(:routes, &Enum.reverse/1)
  end

  defp executable(options) do
    case Keyword.get_lazy(options, :executable, fn -> System.find_executable(@executable) end) do
      nil -> {:error, :executable_missing}
      executable -> {:ok, executable}
    end
  end

  # `-P` reads the input in parallel, which takes one feature per line.
  # `-t` keeps tippecanoe's temporary files in the working directory.
  defp tippecanoe(%{executable: executable, paths: paths, work_dir: work_dir}) do
    arguments = [
      "--output=#{paths.archive}",
      "--minimum-zoom=#{@zoom_min}",
      "--maximum-zoom=#{@zoom_max}",
      "--read-parallel",
      "--named-layer=routes:#{paths.routes}",
      "--named-layer=stops:#{paths.stops}",
      "--no-feature-limit",
      "--no-tile-size-limit",
      "--temporary-directory=#{work_dir}",
      "--quiet"
    ]

    case Command.run(%{
           executable: executable,
           arguments: arguments,
           deadline_ms: @tippecanoe_deadline_ms
         }) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, {:tippecanoe, reason}}
    end
  end

  defp read_archive(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} when size <= @archive_bytes_max ->
        file_result(File.read(path))

      {:ok, %File.Stat{size: size}} ->
        {:error, {:archive_too_large, size}}

      {:error, reason} ->
        {:error, {:file, reason}}
    end
  end

  defp write(request, options) do
    case Writer.write(request, Keyword.get(options, :write_options, [])) do
      :ok -> :ok
      {:error, reason} -> {:error, {:write, reason}}
    end
  end

  defp file_result(:ok), do: :ok
  defp file_result({:ok, content}), do: {:ok, content}
  defp file_result({:error, reason}), do: {:error, {:file, reason}}

  # One feature per line, each ended by a newline.
  defp lines(features), do: Enum.map(features, &[&1, "\n"])

  @doc "What a map page draws with no filter, read from the views."
  @spec gather() :: content()
  def gather do
    agency_names = agency_names()
    route_fetches = FetchView.current(@route_view)

    versions =
      RouteLines.versions(%{
        route_fetches: route_fetches,
        path_fetch_times: FetchView.fetch_times(@route_path_view),
        agency_names: agency_names
      })

    lines =
      for {route_id, version} <- Enum.sort(versions),
          path_fetch = FetchView.current_fetch(@route_path_view, route_id),
          path_fetch != nil,
          do: RouteLines.line(%{version: version, path_fetch: path_fetch})

    %{
      versions: versions,
      lines: lines,
      stops:
        stops(%{route_fetches: route_fetches, versions: versions, agency_names: agency_names})
    }
  end

  defp stops(%{route_fetches: route_fetches, versions: versions, agency_names: agency_names}) do
    drawn = versions |> Map.keys() |> MapSet.new()
    route_names = StopMarkers.route_names(route_fetches)

    route_agency_names =
      StopMarkers.route_agency_names(%{route_fetches: route_fetches, agency_names: agency_names})

    for held_stop <- StopView.current(StopView),
        route_ids = Enum.filter(held_stop.stop["routeIds"], &MapSet.member?(drawn, &1)),
        route_ids != [] do
      marker =
        StopMarkers.marker(%{
          held_stop: held_stop,
          route_names: route_names,
          route_agency_names: route_agency_names
        })

      %{marker: marker, route_ids: route_ids}
    end
  end

  defp agency_names do
    case AgencyView.current(AgencyView) do
      nil ->
        %{}

      %{agency_ids: agency_ids, agencies: agencies} ->
        names = for id <- agency_ids, into: %{}, do: {id, Map.fetch!(agencies, id)["name"]}
        Assert.condition(map_size(names) == length(agency_ids), "one name per agency")
        names
    end
  end
end
