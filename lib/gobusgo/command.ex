defmodule Gobusgo.Command do
  @output_bytes_max 4_096
  @kill_wait_ms 5_000

  @moduledoc """
  Runs an external command to its end or to a deadline, whichever comes
  first, and kills the command's process at the deadline, so a command
  never outlives the call that started it.

  The command's standard output and standard error are read together, and
  the last #{@output_bytes_max} bytes of them are returned, so a command
  that writes without end holds a bounded amount of memory.
  """

  alias Gobusgo.Assert

  @typedoc """
    * `{:exit_status, status, output}`: the command exited with a status
      other than 0.
    * `:deadline_exceeded`: the command ran past its deadline and was killed.
    * `:executable_missing`: the path names no executable file.
  """
  @type error ::
          {:exit_status, pos_integer(), binary()} | :deadline_exceeded | :executable_missing

  @doc "The most bytes of output a run returns."
  @spec output_bytes_max() :: pos_integer()
  def output_bytes_max, do: @output_bytes_max

  @doc """
  Runs `request.executable`, an absolute path, with `request.arguments`, and
  returns its output once it exits with 0.
  """
  @spec run(%{executable: String.t(), arguments: [String.t()], deadline_ms: pos_integer()}) ::
          {:ok, binary()} | {:error, error()}
  def run(%{executable: executable, arguments: arguments, deadline_ms: deadline_ms})
      when is_binary(executable) and is_list(arguments) and is_integer(deadline_ms) do
    Assert.condition(deadline_ms > 0, "deadline must be positive, got: #{deadline_ms}")

    if File.regular?(executable) do
      port =
        Port.open({:spawn_executable, executable}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          :hide,
          args: arguments
        ])

      deadline = System.monotonic_time(:millisecond) + deadline_ms
      collect(%{port: port, deadline: deadline, output: <<>>})
    else
      {:error, :executable_missing}
    end
  end

  # The loop ends at the command's exit or at the deadline, and each message
  # waits at most until the deadline.
  defp collect(%{port: port, deadline: deadline, output: output} = run) do
    wait_ms = max(deadline - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(%{run | output: tail(output <> data)})

      {^port, {:exit_status, 0}} ->
        {:ok, output}

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status, output}}
    after
      wait_ms -> kill(port)
    end
  end

  defp tail(output) when byte_size(output) <= @output_bytes_max, do: output

  defp tail(output) do
    binary_part(output, byte_size(output) - @output_bytes_max, @output_bytes_max)
  end

  # Closing the port alone leaves the process running, since a command that
  # reads no input never sees its input close. A killed process exits, and
  # its port closes with it; the close message covers a process that has not
  # exited within the wait, and does nothing to a port that is closed.
  defp kill(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        {_output, _status} =
          System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

      nil ->
        :ok
    end

    receive do
      {^port, {:exit_status, _status}} -> :ok
    after
      @kill_wait_ms -> send(port, {self(), :close})
    end

    flush(port)
    {:error, :deadline_exceeded}
  end

  # The messages the port sent before it closed would otherwise stay in the
  # caller's mailbox.
  defp flush(port) do
    receive do
      {^port, _message} -> flush(port)
    after
      0 -> :ok
    end
  end
end
