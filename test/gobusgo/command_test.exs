defmodule Gobusgo.CommandTest do
  # Runs small shell scripts the test writes to its temporary directory, so
  # each outcome of a command is produced on purpose: success, a failing exit
  # status, output past the bound, and a command that outlasts its deadline,
  # whose process the test then looks for.
  use ExUnit.Case, async: true

  alias Gobusgo.Command

  @moduletag :tmp_dir

  defp script(tmp_dir, name, body) do
    path = Path.join(tmp_dir, name)
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp run(executable, arguments, deadline_ms \\ 5_000) do
    Command.run(%{executable: executable, arguments: arguments, deadline_ms: deadline_ms})
  end

  describe "run/1" do
    test "returns the output of a command that exits with 0", %{tmp_dir: tmp_dir} do
      executable = script(tmp_dir, "echo.sh", ~s(echo "$1"; echo "$2" >&2\n))

      assert run(executable, ["out", "err"]) == {:ok, "out\nerr\n"}
    end

    test "returns the status and the output of a command that fails", %{tmp_dir: tmp_dir} do
      executable = script(tmp_dir, "fail.sh", "echo broken\nexit 3\n")

      assert run(executable, []) == {:error, {:exit_status, 3, "broken\n"}}
    end

    test "keeps only the end of a long output", %{tmp_dir: tmp_dir} do
      byte_count = Command.output_bytes_max() * 2

      executable =
        script(tmp_dir, "long.sh", "head -c #{byte_count} /dev/zero | tr '\\0' 'a'\necho end\n")

      {:ok, output} = run(executable, [])

      assert byte_size(output) == Command.output_bytes_max()
      assert String.ends_with?(output, "aend\n")
    end

    test "kills a command that outlasts its deadline", %{tmp_dir: tmp_dir} do
      marker = Path.join(tmp_dir, "pid")
      executable = script(tmp_dir, "sleep.sh", "echo $$ > #{marker}\nexec sleep 30\n")

      # The deadline leaves the script ample time to write its process
      # identifier, and ends long before its sleep would.
      assert run(executable, [], 1_500) == {:error, :deadline_exceeded}

      pid = marker |> File.read!() |> String.trim()
      assert {_output, 1} = System.cmd("kill", ["-0", pid], stderr_to_stdout: true)
    end

    test "returns :executable_missing for a path that names no executable", %{tmp_dir: tmp_dir} do
      assert run(Path.join(tmp_dir, "absent"), []) == {:error, :executable_missing}
    end
  end
end
