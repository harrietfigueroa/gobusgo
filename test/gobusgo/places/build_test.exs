defmodule Gobusgo.Places.BuildTest do
  # Runs a build over a stand-in for osmium that copies its input file through
  # every step, so the extract file the test writes holds the export's records
  # and the build's places are those records' selection and merge.
  use ExUnit.Case, async: true

  alias Gobusgo.Places.Build

  @moduletag :tmp_dir

  @bounds %{south: 47.0, west: -123.0, north: 48.0, east: -121.5}
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
      -s|-b|-f|-a) ;;
      *)
        case "$argument" in
          -*) ;;
          *) if [ -z "$input" ]; then input="$argument"; fi ;;
        esac
        ;;
    esac
    previous="$argument"
  done
  cat "$input" > "$output"
  """

  defp record(tags, lon, lat) do
    properties = Map.merge(%{"@type" => "node", "@id" => 1}, tags)
    geometry = %{"type" => "Point", "coordinates" => [lon, lat]}

    "\u001e" <>
      JSON.encode!(%{"type" => "Feature", "properties" => properties, "geometry" => geometry}) <>
      "\n"
  end

  setup %{tmp_dir: tmp_dir} do
    executable = Path.join(tmp_dir, "osmium")
    File.write!(executable, @stand_in)
    File.chmod!(executable, 0o755)

    extract_path = Path.join(tmp_dir, "washington.osm.pbf")

    records =
      record(%{"name" => "Central Library", "amenity" => "library"}, -122.33, 47.6) <>
        record(
          %{"name" => "Central Library", "amenity" => "library", "alt_name" => "Main"},
          -122.3301,
          47.6
        ) <>
        record(%{"name" => "Pine St", "highway" => "bus_stop"}, -122.3, 47.6) <>
        record(%{"name" => "Portland", "place" => "city"}, -122.6, 45.5)

    File.write!(extract_path, records)
    %{executable: executable, extract_path: extract_path, tmp_dir: tmp_dir}
  end

  defp request(context, working_dir),
    do: %{extract_path: context.extract_path, bounds: @bounds, working_dir: working_dir}

  test "selects, merges, and counts", context do
    assert {:ok, result} = Build.run(request(context, nil), executable: context.executable)

    assert result.source_date == "2026-11-08T21:21:00Z"
    assert [%{name: "Central Library", aliases: ["Main"]}] = result.places
    assert result.merged_count == 1
    assert %{read: 4, stops: 1, outside: 1, kept: 2} = result.selection

    assert Enum.map(result.steps, & &1.name) == [
             :fileinfo,
             :extract,
             :names,
             :categories,
             :export
           ]
  end

  test "gives each place a locality from its address or the nearest settlement", context do
    records =
      record(
        %{
          "name" => "Corner Cafe",
          "amenity" => "cafe",
          "addr:housenumber" => "400",
          "addr:street" => "Pine Street"
        },
        -122.34,
        47.61
      ) <>
        record(%{"name" => "Bakery", "shop" => "bakery"}, -122.3375, 47.6113) <>
        record(%{"name" => "Denny Triangle", "place" => "neighbourhood"}, -122.336, 47.618) <>
        record(%{"name" => "Seattle", "place" => "city"}, -122.3301, 47.6038)

    File.write!(context.extract_path, records)

    assert {:ok, result} = Build.run(request(context, nil), executable: context.executable)

    localities = Map.new(result.places, &{&1.name, &1.locality})
    assert localities["Corner Cafe"] == "400 Pine Street"
    assert localities["Bakery"] == "Denny Triangle, Seattle"
    assert localities["Denny Triangle"] == "Seattle"
    assert localities["Seattle"] == ""
  end

  test "removes the files it wrote from a working directory it was given", context do
    working_dir = Path.join(context.tmp_dir, "work")

    assert {:ok, _result} =
             Build.run(request(context, working_dir), executable: context.executable)

    assert File.ls!(working_dir) == []
  end

  test "returns the extractor's error", context do
    assert Build.run(request(context, nil), executable: nil) == {:error, :executable_missing}
  end
end
