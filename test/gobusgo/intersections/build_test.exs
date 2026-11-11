defmodule Gobusgo.Intersections.BuildTest do
  # Runs the part of the build after osmium over the hand-written export of
  # Gobusgo.Test.IntersectionOpl, and the whole build against an osmium
  # stand-in that copies its input through every step.
  use ExUnit.Case, async: true

  alias Gobusgo.Intersections.Build
  alias Gobusgo.Test.IntersectionOpl

  @moduletag :tmp_dir

  defp select(service_roads) do
    Build.select(%{
      lines: IntersectionOpl.lines_fun(),
      bounds: IntersectionOpl.bounds(),
      service_roads: service_roads
    })
  end

  describe "select/1" do
    test "makes the intersections of the shared nodes under both streets" do
      assert %{intersection_count: 2, pair_count: 2, streets: streets} = select(false)

      assert Enum.map(streets, &{&1.key, length(&1.crossings)}) ==
               [{"3RD AVE", 1}, {"4TH AVE", 1}, {"PINE ST", 2}]
    end

    test "merges the two nodes of a dual carriageway into one crossing" do
      %{streets: [third | _rest]} = select(false)
      assert [pine] = Enum.filter(third.crossings, &(&1.other == "PINE ST"))
      assert {pine.lat_microdegrees, pine.lon_microdegrees} == {47_610_750, -122_337_200}
    end

    test "adds the crossings of service roads when they are kept" do
      without = select(false)
      with_service = select(true)

      assert with_service.intersection_count == without.intersection_count + 3
      assert Enum.any?(with_service.streets, &(&1.key == "PARKING AISLE"))
    end

    test "carries the counts of the selection" do
      assert %{selection: %{ways_kept: 6, shared_nodes: 4}} = select(false)
    end
  end

  describe "run/2" do
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
            *) if [ -z "$input" ] && [ "$argument" != "w/name" ]; then input="$argument"; fi ;;
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
      File.write!(extract_path, Enum.join(IntersectionOpl.lines(), "\n") <> "\n")

      request = %{
        extract_path: extract_path,
        bounds: IntersectionOpl.bounds(),
        working_dir: Path.join(tmp_dir, "work"),
        service_roads: false
      }

      %{executable: executable, request: request}
    end

    test "builds the streets from the export of the last step", context do
      assert {:ok, result} = Build.run(context.request, executable: context.executable)
      assert result.source_date == "2026-11-08T21:21:00Z"
      assert result.intersection_count == 2
      assert Enum.map(result.streets, & &1.key) == ["3RD AVE", "4TH AVE", "PINE ST"]
      assert Enum.map(result.steps, & &1.name) == [:fileinfo, :roads, :names, :extract, :export]
    end

    test "removes the files it wrote", context do
      assert {:ok, _result} = Build.run(context.request, executable: context.executable)
      assert File.ls!(context.request.working_dir) == []
    end

    test "returns the extractor's error", context do
      assert Build.run(context.request, executable: nil) == {:error, :executable_missing}
    end

    test "uses a temporary directory it removes when none is given", context do
      request = %{context.request | working_dir: nil}
      assert {:ok, %{intersection_count: 2}} = Build.run(request, executable: context.executable)
    end
  end
end
