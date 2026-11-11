defmodule Mix.Tasks.Gobusgo.Intersections.BuildTest do
  # Runs the task with an osmium stand-in first on the PATH, which copies its
  # input through every step, and reads the summary the task prints and the
  # files it stores. The PATH is process-wide, so this module does not run
  # concurrently with others.
  use ExUnit.Case, async: false

  alias Gobusgo.Test.AppEnv
  alias Gobusgo.Test.IntersectionOpl
  alias Mix.Tasks.Gobusgo.Intersections.Build

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
    File.write!(extract_path, Enum.join(IntersectionOpl.lines(), "\n") <> "\n")

    for backend <- [Gobusgo.Writer.LocalFile, Gobusgo.Deleter.LocalFile, Gobusgo.Reader.LocalFile] do
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

  test "stores the files and the manifest and prints the counts and the step times", %{
    extract_path: extract_path,
    tmp_dir: tmp_dir
  } do
    Build.run(["--extract", extract_path, "--bounds", "47,-123,48,-122"])

    [manifest_path] =
      tmp_dir |> Path.join("data/intersections/manifest-*.json") |> Path.wildcard()

    manifest = manifest_path |> File.read!() |> JSON.decode!()

    assert manifest["intersectionCount"] == 2
    assert manifest["streetCount"] == 3
    assert File.exists?(Path.join(tmp_dir, "data" <> manifest["index"]["path"]))

    output = Enum.join(messages(), "\n")
    assert output =~ "Step roads:"
    assert output =~ "Pairs 2, intersections 2, streets 3"
    assert output =~ "Stored 1 shards: gzip p50"
  end

  test "refuses with neither --bounds nor a basemap manifest", %{extract_path: extract_path} do
    assert_raise Mix.Error, ~r/no --bounds/, fn -> Build.run(["--extract", extract_path]) end
  end

  test "refuses a missing --extract" do
    assert_raise Mix.Error, ~r/missing --extract/, fn ->
      Build.run(["--bounds", "47,-123,48,-122"])
    end
  end

  test "refuses bad --bounds", %{extract_path: extract_path} do
    assert_raise Mix.Error, ~r/--bounds must be/, fn ->
      Build.run(["--extract", extract_path, "--bounds", "48,-123,47,-122"])
    end
  end
end
