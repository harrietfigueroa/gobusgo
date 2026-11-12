defmodule Mix.Tasks.Gobusgo.Places.BuildTest do
  # Runs the task with an osmium stand-in first on the PATH, which copies its
  # input through every step, and reads the summary the task prints and the
  # records JSON it writes. The PATH is process-wide, so this module does not
  # run concurrently with others.
  use ExUnit.Case, async: false

  alias Gobusgo.Test.AppEnv
  alias Mix.Tasks.Gobusgo.Places.Build

  @moduletag :tmp_dir

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

  setup %{tmp_dir: tmp_dir} do
    bin = Path.join(tmp_dir, "bin")
    File.mkdir_p!(bin)
    executable = Path.join(bin, "osmium")
    File.write!(executable, @stand_in)
    File.chmod!(executable, 0o755)

    path = System.get_env("PATH")
    System.put_env("PATH", bin <> ":" <> path)
    on_exit(fn -> System.put_env("PATH", path) end)

    properties = %{
      "@type" => "node",
      "@id" => 1,
      "name" => "Central Library",
      "amenity" => "library"
    }

    geometry = %{"type" => "Point", "coordinates" => [-122.33, 47.6]}

    feature =
      JSON.encode!(%{"type" => "Feature", "properties" => properties, "geometry" => geometry})

    extract_path = Path.join(tmp_dir, "washington.osm.pbf")
    File.write!(extract_path, "\u001e" <> feature <> "\n")

    for backend <- [Gobusgo.Writer.LocalFile, Gobusgo.Deleter.LocalFile] do
      configured = Application.get_env(:gobusgo, backend)
      Application.put_env(:gobusgo, backend, base_dir: Path.join(tmp_dir, "data"))
      on_exit(fn -> Application.put_env(:gobusgo, backend, configured) end)
    end

    AppEnv.put(:basemap, dir: Path.join(tmp_dir, "basemap"))
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(Mix.Shell.IO) end)
    %{extract_path: extract_path}
  end

  defp messages(acc \\ []) do
    receive do
      {:mix_shell, :info, [message]} -> messages([message | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  test "writes the rows and prints the counts and the step times", %{
    extract_path: extract_path,
    tmp_dir: tmp_dir
  } do
    records_path = Path.join(tmp_dir, "records.json")

    Build.run([
      "--extract",
      extract_path,
      "--bounds",
      "47,-123,48,-121.5",
      "--records-json",
      records_path
    ])

    decoded = records_path |> File.read!() |> JSON.decode!()
    assert decoded["sourceDate"] == "2026-11-08T21:21:00Z"

    assert [["Central Library", [], 47_600_000, -122_330_000, _index, 100, 0, ""]] =
             decoded["places"]

    manifest = tmp_dir |> Path.join("data/places/manifest.json") |> File.read!() |> JSON.decode!()
    assert manifest["placeCount"] == 1
    assert File.exists?(Path.join(tmp_dir, "data/" <> manifest["file"]["path"]))

    output = Enum.join(messages(), "\n")
    assert output =~ "Step extract:"
    assert output =~ "Read 1, named 1"
  end

  test "refuses with neither --bounds nor a basemap manifest", %{extract_path: extract_path} do
    assert_raise Mix.Error, ~r/no --bounds/, fn -> Build.run(["--extract", extract_path]) end
  end

  test "refuses a missing --extract" do
    assert_raise Mix.Error, ~r/missing --extract/, fn ->
      Build.run(["--bounds", "47,-123,48,-121.5"])
    end
  end

  test "refuses bad --bounds", %{extract_path: extract_path} do
    assert_raise Mix.Error, ~r/--bounds must be/, fn ->
      Build.run(["--extract", extract_path, "--bounds", "48,-123,47,-121.5"])
    end
  end
end
