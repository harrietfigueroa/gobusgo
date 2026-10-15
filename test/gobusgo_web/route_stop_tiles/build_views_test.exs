defmodule GobusgoWeb.RouteStopTiles.BuildViewsTest do
  # Runs builds over what the application's route views hold, with a
  # stand-in for tippecanoe that writes its inputs where the archive goes.
  # The views are filled with the record values the records modules build,
  # and a route's path is fetched again, unchanged or changed, between two
  # runs. The views are global state, hence the non-async case.
  use ExUnit.Case, async: false

  alias Gobusgo.OneBusAway.FetchView
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RoutePathBatch
  alias GobusgoWeb.RouteStopTiles
  alias GobusgoWeb.RouteStopTiles.Build

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @route_view Gobusgo.OneBusAway.RouteView
  @route_path_view Gobusgo.OneBusAway.RoutePathView
  @fetched_at ~U[2026-10-14 01:00:00Z]
  @built_at ~U[2026-10-14 15:30:00.000000Z]
  @points "_p~iF~ps|U_ulLnnqC"

  @stand_in """
  #!/bin/sh
  inputs=""
  for argument in "$@"; do
    case "$argument" in
      --output=*) output="${argument#--output=}" ;;
      --named-layer=*) inputs="$inputs ${argument#--named-layer=*:}" ;;
    esac
  done
  cat $inputs > "$output"
  """

  setup %{tmp_dir: tmp_dir} do
    restart_views()
    on_exit(&restart_views/0)

    executable = Path.join(tmp_dir, "tippecanoe")
    File.write!(executable, @stand_in)
    File.chmod!(executable, 0o755)

    server =
      start_supervised!(
        {RouteStopTiles,
         name: :"tiles_#{System.unique_integer([:positive])}",
         read_options: [backend: Gobusgo.Reader.LocalFile, base_dir: Path.join(tmp_dir, "data")]}
      )

    apply_route(%{sequence: 0})
    apply_path(@points, %{sequence: 0})
    %{executable: executable, server: server}
  end

  defp restart_views do
    for view <- [@route_view, @route_path_view] do
      :ok = Supervisor.terminate_child(Gobusgo.Supervisor, view)
      {:ok, _pid} = Supervisor.restart_child(Gobusgo.Supervisor, view)
    end
  end

  defp fetch(sequence) do
    %{
      fetched_at: DateTime.add(@fetched_at, sequence, :hour),
      data_sha256: String.duplicate("ab", 32),
      request_id: "0199c4a2-7e1b-7a3f-9d20-" <> String.pad_leading("#{sequence}", 12, "0")
    }
  end

  defp apply_route(%{sequence: sequence}) do
    route = %{
      id: "1_100",
      agency_id: "1",
      short_name: "10",
      long_name: nil,
      description: nil,
      type: 3,
      color: nil,
      text_color: nil,
      url: nil
    }

    record =
      RouteBatch.Records.build(
        Map.merge(fetch(sequence), %{
          agency_id: "1",
          destination: "raw/oba/routes-for-agency/dt=2026-10-14/agency=1/file.json.gz",
          routes: [route]
        })
      )

    :ok = FetchView.apply_records(@route_view, [record.value])
  end

  defp apply_path(points, %{sequence: sequence}) do
    record =
      RoutePathBatch.Records.build(
        Map.merge(fetch(sequence), %{
          route_id: "1_100",
          destination: "raw/oba/stops-for-route/dt=2026-10-14/route=1_100/file.json.gz",
          route_path: %{
            route_id: "1_100",
            stop_ids: [],
            polylines: [%{points: points, point_count: 2, levels: nil}],
            stop_groupings: [],
            stops: []
          }
        })
      )

    :ok = FetchView.apply_records(@route_path_view, [record.value])
  end

  defp run(%{tmp_dir: tmp_dir, executable: executable, server: server}, minutes) do
    Build.run(
      server: server,
      executable: executable,
      now: fn -> DateTime.add(@built_at, minutes, :minute) end,
      write_options: [backend: Gobusgo.Writer.LocalFile, base_dir: Path.join(tmp_dir, "data")]
    )
  end

  test "builds nothing after a path is fetched again unchanged", context do
    {:ok, %{route_count: 1}} = run(context, 0)

    apply_path(@points, %{sequence: 1})

    assert run(context, 10) == {:ok, :unchanged}
  end

  test "builds again after a path is fetched again changed", context do
    {:ok, %{route_count: 1}} = run(context, 0)

    apply_path("_p~iF~ps|U_ulLnnqD", %{sequence: 1})

    assert {:ok, %{route_count: 1}} = run(context, 10)
  end
end
