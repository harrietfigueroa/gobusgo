defmodule Gobusgo.WalkGraph.BuildTest do
  # Plans the osmium steps, and runs the whole build against an osmium
  # stand-in first on the PATH that copies its input through every step, so
  # the build reads the hand-written export it is given as its extract.
  use ExUnit.Case, async: false

  alias Gobusgo.WalkGraph.Build
  alias Gobusgo.WalkGraph.Extractor

  @moduletag :tmp_dir

  @bounds %{south: 47.0, west: -123.0, north: 48.0, east: -122.0}

  @lines [
    "n1 T x-122.3400 y47.6100",
    "n2 T x-122.3390 y47.6100",
    "n3 T x-122.3380 y47.6100",
    "w10 Thighway=residential Nn1,n2,n3",
    "w11 Thighway=motorway Nn1,n3"
  ]

  @stand_in """
  #!/bin/sh
  subcommand="$1"
  shift
  if [ "$subcommand" = fileinfo ]; then
    echo 2026-11-08T21:21:00Z
    exit 0
  fi
  input=""
  output=""
  previous=""
  for argument in "$@"; do
    case "$previous" in
      -o) output="$argument" ;;
      -s|-b|-f) ;;
      *)
        case "$argument" in
          -*) ;;
          w/*) ;;
          *) if [ -z "$input" ]; then input="$argument"; fi ;;
        esac
        ;;
    esac
    previous="$argument"
  done
  cat "$input" > "$output"
  """

  setup %{tmp_dir: tmp_dir} do
    bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin)
    executable = Path.join(bin, "osmium")
    File.write!(executable, @stand_in)
    File.chmod!(executable, 0o755)

    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)

    extract_path = Path.join(tmp_dir, "washington.osm.pbf")
    File.write!(extract_path, Enum.join(@lines, "\n") <> "\n")
    %{extract_path: extract_path}
  end

  describe "Extractor.plan/1" do
    test "filters the walkable ways, cuts the bounds, and exports text, in that order" do
      %{steps: steps} =
        Extractor.plan(%{extract_path: "in.pbf", bounds: @bounds, working_dir: "/work"})

      assert Enum.map(steps, & &1.name) == [:ways, :extract, :export]
      [ways, extract, export] = steps
      assert ["tags-filter", "in.pbf", "w/highway=" <> _classes | _rest] = ways.arguments

      assert extract.arguments == [
               "extract",
               "-s",
               "complete_ways",
               "-b",
               "-123.0,47.0,-122.0,48.0",
               "/work/ways.osm.pbf",
               "-o",
               "/work/cut.osm.pbf",
               "--overwrite"
             ]

      assert export.arguments == [
               "cat",
               "/work/cut.osm.pbf",
               "-f",
               "opl,add_metadata=false",
               "-o",
               "/work/ways.opl",
               "--overwrite"
             ]
    end
  end

  describe "run/2" do
    test "builds the pieces of the export of the last step", %{
      extract_path: extract_path,
      tmp_dir: tmp_dir
    } do
      request = %{
        extract_path: extract_path,
        bounds: @bounds,
        working_dir: Path.join(tmp_dir, "work")
      }

      assert {:ok, result} = Build.run(request, [])
      assert result.source_date == "2026-11-08T21:21:00Z"
      assert result.selection.ways_kept == 1
      assert result.selection.ways_excluded == %{motorway: 1}
      assert Map.keys(result.tiles) == [{4_761, -8_156}]
      assert Enum.map(result.steps, & &1.name) == [:fileinfo, :ways, :extract, :export]
    end

    test "removes the files it wrote from a working directory it was given", %{
      extract_path: extract_path,
      tmp_dir: tmp_dir
    } do
      work = Path.join(tmp_dir, "work")

      assert {:ok, _result} =
               Build.run(%{extract_path: extract_path, bounds: @bounds, working_dir: work}, [])

      assert File.ls!(work) == []
    end

    test "uses a temporary directory it removes when none is given", %{extract_path: extract_path} do
      assert {:ok, _result} =
               Build.run(%{extract_path: extract_path, bounds: @bounds, working_dir: nil}, [])
    end

    test "returns the extractor's error", %{extract_path: extract_path, tmp_dir: tmp_dir} do
      File.rm!(Path.join(tmp_dir, "bin/osmium"))

      assert {:error, :executable_missing} =
               Build.run(%{extract_path: extract_path, bounds: @bounds, working_dir: nil},
                 executable: nil
               )
    end
  end
end
