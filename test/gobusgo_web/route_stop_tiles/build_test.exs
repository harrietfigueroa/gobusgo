defmodule GobusgoWeb.RouteStopTiles.BuildTest do
  # Runs builds over literal content with a stand-in for tippecanoe: a shell
  # script that writes its two input files, one after the other, where the
  # archive goes. The archive the local writer stores in the test's directory
  # is therefore the features the build handed tippecanoe, and each test
  # reads what was stored and which archive the process holds as current.
  use ExUnit.Case, async: true

  alias GobusgoWeb.RouteStopTiles
  alias GobusgoWeb.RouteStopTiles.Build

  @moduletag :tmp_dir
  @moduletag capture_log: true

  @built_at ~U[2026-10-14 15:30:00.000000Z]
  @line %{
    id: "1_100",
    color: "#ff0000",
    short_name: "10",
    long_name: nil,
    agency_name: "Metro",
    polylines: ["_p~iF~ps|U_ulLnnqC"]
  }
  @marker %{
    id: "1_500",
    lat: 47.6,
    lon: -122.3,
    name: "Pine St",
    code: nil,
    direction: "N",
    routes: ["10"],
    agencies: ["Metro"]
  }
  @content %{
    lines: [@line],
    stops: [%{marker: @marker, route_ids: ["1_100"]}]
  }
  @later DateTime.add(@built_at, 60)

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
    executable = Path.join(tmp_dir, "tippecanoe")
    File.write!(executable, @stand_in)
    File.chmod!(executable, 0o755)

    server =
      start_supervised!(
        {RouteStopTiles,
         name: :"tiles_#{System.unique_integer([:positive])}", read_options: read_options(tmp_dir)}
      )

    %{executable: executable, server: server}
  end

  defp read_options(tmp_dir),
    do: [backend: Gobusgo.Reader.LocalFile, base_dir: Path.join(tmp_dir, "data")]

  defp run(%{tmp_dir: tmp_dir, executable: executable, server: server}, content, overrides \\ []) do
    [
      server: server,
      executable: executable,
      now: fn -> @built_at end,
      gather: fn -> content end,
      write_options: [backend: Gobusgo.Writer.LocalFile, base_dir: Path.join(tmp_dir, "data")]
    ]
    |> Keyword.merge(overrides)
    |> Build.run()
  end

  defp stored(%{tmp_dir: tmp_dir}, destination) do
    tmp_dir |> Path.join("data") |> Path.join(destination) |> File.read!()
  end

  test "stores the archive of the lines and stops at the destination of its build", context do
    destination = RouteStopTiles.destination(@built_at)

    assert {:ok, %{destination: ^destination, route_count: 1, stop_count: 1}} =
             run(context, @content)

    features =
      context
      |> stored(destination)
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert Enum.map(features, & &1["geometry"]["type"]) == ["MultiLineString", "Point"]
  end

  test "makes the archive it stores the current one", context do
    {:ok, %{destination: destination}} = run(context, @content)

    assert RouteStopTiles.current_destination(context.server) == destination
  end

  test "builds nothing for the content of the current archive", context do
    {:ok, _build} = run(context, @content)

    assert run(context, @content, now: fn -> @later end) == {:ok, :unchanged}
  end

  for {name, change} <- [
        {"a line's path",
         quote(do: put_in(@content, [:lines], [%{@line | polylines: ["_p~iF~ps|U_ulLnnqD"]}]))},
        {"a route's name", quote(do: put_in(@content, [:lines], [%{@line | short_name: "11"}]))},
        {"a route's agency name",
         quote(do: put_in(@content, [:lines], [%{@line | agency_name: "King County Metro"}]))},
        {"a stop's name",
         quote(
           do:
             put_in(@content, [:stops], [
               %{marker: %{@marker | name: "Pike St"}, route_ids: ["1_100"]}
             ])
         )},
        {"a stop's routes",
         quote(
           do: put_in(@content, [:stops], [%{marker: @marker, route_ids: ["1_100", "1_200"]}])
         )}
      ] do
    test "builds again when #{name} changes", context do
      {:ok, _build} = run(context, @content)

      assert {:ok, %{destination: destination}} =
               run(context, unquote(change), now: fn -> @later end)

      assert destination == RouteStopTiles.destination(@later)
    end
  end

  test "builds nothing while the views hold no line", context do
    assert run(context, %{lines: [], stops: []}) == {:ok, :empty}
    assert RouteStopTiles.current_destination(context.server) == nil
  end

  test "leaves out and counts a route whose polyline does not decode", context do
    content = %{@content | lines: [%{@line | polylines: ["_p~iF~ps|U_ulL"]}]}

    assert {:ok, %{route_count: 0, route_skipped_count: 1}} = run(context, content)
  end

  test "keeps the current archive when tippecanoe fails", context do
    {:ok, %{destination: destination}} = run(context, @content)
    File.write!(context.executable, "#!/bin/sh\necho broken\nexit 2\n")
    content = put_in(@content, [:lines], [%{@line | short_name: "11"}])

    assert run(context, content, now: fn -> @later end) ==
             {:error, {:tippecanoe, {:exit_status, 2, "broken\n"}}}

    assert RouteStopTiles.current_destination(context.server) == destination
  end

  test "returns :executable_missing when tippecanoe is not installed", context do
    assert run(context, @content, executable: nil) == {:error, :executable_missing}
  end

  test "leaves no working directory behind", context do
    before = Path.wildcard(Path.join(System.tmp_dir!(), "gobusgo-route-stop-tiles-*"))
    {:ok, _build} = run(context, @content)

    assert Path.wildcard(Path.join(System.tmp_dir!(), "gobusgo-route-stop-tiles-*")) -- before ==
             []
  end

  test "a process started over stored archives holds the newest", context do
    {:ok, _build} = run(context, @content)
    content = put_in(@content, [:lines], [%{@line | short_name: "11"}])

    {:ok, %{destination: newest}} =
      run(context, content, now: fn -> DateTime.add(@built_at, 86_400) end)

    restarted =
      start_supervised!(
        {RouteStopTiles, name: :restarted, read_options: read_options(context.tmp_dir)},
        id: :restarted
      )

    assert RouteStopTiles.current_destination(restarted) == newest
  end
end
