defmodule Gobusgo.Intersections.ExtractorTest do
  # Runs the osmium steps against a stand-in for osmium: a shell script that
  # answers `fileinfo` with a timestamp and copies the one input file of every
  # other subcommand to its output, so the export the extractor returns is the
  # input file's content. The step arguments are checked on the pure plan.
  use ExUnit.Case, async: true

  alias Gobusgo.Intersections.Classification
  alias Gobusgo.Intersections.Extractor

  @moduletag :tmp_dir

  @bounds %{south: 46.5, west: -123.25, north: 48.75, east: -121.5}
  @timestamp "2026-11-08T21:21:00Z"
  @stand_in """
  #!/bin/sh
  subcommand="$1"
  shift
  if [ "$subcommand" = fileinfo ]; then
    echo "#{@timestamp}"
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
    executable = Path.join(tmp_dir, "osmium")
    File.write!(executable, @stand_in)
    File.chmod!(executable, 0o755)
    extract_path = Path.join(tmp_dir, "washington.osm.pbf")
    File.write!(extract_path, "records\n")

    request = %{
      extract_path: extract_path,
      bounds: @bounds,
      working_dir: Path.join(tmp_dir, "work"),
      service_roads: false
    }

    %{executable: executable, request: request}
  end

  describe "plan/1" do
    test "filters the roads, then the names, then cuts the bounds, then exports", %{
      request: request
    } do
      %{steps: steps} = Extractor.plan(request)
      assert Enum.map(steps, & &1.name) == [:roads, :names, :extract, :export]
      [roads, names, extract, export] = steps

      assert Classification.tag_filter(false) in roads.arguments
      assert "w/name" in names.arguments

      assert ["extract", "-s", "complete_ways", "-b", "-123.25,46.5,-121.5,48.75" | _rest] =
               extract.arguments

      assert ["cat" | _rest] = export.arguments
      assert "opl,add_metadata=false" in export.arguments
    end

    test "names the service class only when service roads are kept", %{request: request} do
      [with_service, without] =
        for service_roads <- [true, false] do
          %{steps: [roads | _steps]} = Extractor.plan(%{request | service_roads: service_roads})
          Enum.find(roads.arguments, &String.starts_with?(&1, "w/highway="))
        end

      assert String.ends_with?(with_service, ",service")
      refute String.contains?(without, "service")
    end
  end

  describe "split_lines/1" do
    test "splits on newlines wherever a chunk ends" do
      assert Enum.to_list(Extractor.split_lines(["a\nb", "c\n\nd", "\n"])) == ["a", "bc", "", "d"]
    end

    test "keeps a last line that has no line end" do
      assert Enum.to_list(Extractor.split_lines(["a\nb"])) == ["a", "b"]
    end
  end

  describe "run/2" do
    test "returns the source date and the export of the last step", context do
      assert {:ok, result} = Extractor.run(context.request, executable: context.executable)
      assert result.source_date == @timestamp
      assert File.read!(result.export_path) == "records\n"

      assert Enum.map(result.steps, & &1.name) == [:fileinfo, :roads, :names, :extract, :export]
      assert Enum.all?(result.steps, &is_integer(&1.duration_ms))
    end

    test "lists the intermediate files it wrote, apart from the export", context do
      assert {:ok, %{intermediate_paths: paths, export_path: export_path}} =
               Extractor.run(context.request, executable: context.executable)

      assert length(paths) == 3
      refute export_path in paths
      assert Enum.all?(paths, &File.exists?/1)
    end

    test "refuses an extract whose header has no replication timestamp", context do
      File.write!(context.executable, "#!/bin/sh\necho\n")

      assert Extractor.run(context.request, executable: context.executable) ==
               {:error, :source_date_missing}
    end

    test "refuses a timestamp that is not a UTC date and time", context do
      File.write!(context.executable, "#!/bin/sh\necho yesterday\n")

      assert Extractor.run(context.request, executable: context.executable) ==
               {:error, {:invalid_source_date, "yesterday"}}
    end

    test "names the step that fails", context do
      File.write!(
        context.executable,
        "#!/bin/sh\nif [ \"$1\" = fileinfo ]; then echo #{@timestamp}; exit 0; fi\nexit 2\n"
      )

      assert {:error, {:step, :roads, {:exit_status, 2, _output}}} =
               Extractor.run(context.request, executable: context.executable)
    end

    test "names the step whose output is missing", context do
      File.write!(
        context.executable,
        "#!/bin/sh\nif [ \"$1\" = fileinfo ]; then echo #{@timestamp}; fi\nexit 0\n"
      )

      assert {:error, {:step, :roads, :output_missing}} =
               Extractor.run(context.request, executable: context.executable)
    end

    test "returns :executable_missing when osmium is not installed", context do
      assert Extractor.run(context.request, executable: nil) == {:error, :executable_missing}
    end
  end
end
