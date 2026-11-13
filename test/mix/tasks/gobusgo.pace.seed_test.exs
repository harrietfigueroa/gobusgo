defmodule Mix.Tasks.Gobusgo.Pace.SeedTest do
  # Runs the task against a local store under the test's temporary directory,
  # which the local backends are pointed at for the run, and reads what it
  # prints from the Mix shell. The learning is checked in
  # `Gobusgo.Pace.SeedTest`; this checks the arguments, the skip, and the
  # report.
  use ExUnit.Case, async: false

  alias Gobusgo.Writer
  alias Mix.Tasks.Gobusgo.Pace.Seed

  @moduletag :tmp_dir
  @moduletag capture_log: true

  setup context do
    shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)

    originals =
      for module <- [Gobusgo.Reader.LocalFile, Gobusgo.Writer.LocalFile] do
        {module, Application.get_env(:gobusgo, module, [])}
      end

    for {module, _env} <- originals do
      Application.put_env(:gobusgo, module, base_dir: context.tmp_dir)
    end

    on_exit(fn ->
      Mix.shell(shell)

      for {module, env} <- originals do
        Application.put_env(:gobusgo, module, env)
      end
    end)
  end

  defp store_aggregate(context, date) do
    destination = "paces/daily/dt=#{date}/node1-x.json.gz"
    :ok = Writer.write(%{destination: destination, content: "{}"}, base_dir: context.tmp_dir)
  end

  test "says that a date with a file is skipped", context do
    store_aggregate(context, "2026-11-11")

    Seed.run(["--date", "2026-11-11"])

    assert_received {:mix_shell, :info, [message]}
    assert message == "2026-11-11: skipped, a file is already stored for the date"
  end

  test "reports each date of a range", context do
    store_aggregate(context, "2026-11-10")
    store_aggregate(context, "2026-11-11")

    Seed.run(["--date", "2026-11-10", "--to", "2026-11-11"])

    assert_received {:mix_shell, :info, ["2026-11-10: skipped" <> _rest]}
    assert_received {:mix_shell, :info, ["2026-11-11: skipped" <> _rest]}
  end

  test "reports a date with no stored fetch as writing no file" do
    Seed.run(["--date", "2026-11-11"])

    assert_received {:mix_shell, :info, [message]}
    assert message =~ "2026-11-11: wrote no file, 0 cells, 0.0 meters, 0 fetches read"
  end

  for {name, arguments} <- [
        {"no date", []},
        {"a date that is not one", ["--date", "yesterday"]},
        {"an unknown flag", ["--date", "2026-11-11", "--force"]},
        {"a range that runs backward", ["--date", "2026-11-11", "--to", "2026-11-10"]},
        {"a range of 32 days", ["--date", "2026-10-01", "--to", "2026-11-01"]}
      ] do
    test "refuses #{name}" do
      assert_raise Mix.Error, fn -> Seed.run(unquote(arguments)) end
    end
  end
end
