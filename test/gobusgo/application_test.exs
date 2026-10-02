defmodule Gobusgo.ApplicationTest do
  # Verifies the application boots: its supervisor and the HTTP endpoint the
  # supervisor starts are alive.
  use ExUnit.Case, async: true

  test "the supervision tree is running" do
    assert is_pid(Process.whereis(Gobusgo.Supervisor))
  end

  test "the supervisor runs the HTTP endpoint" do
    assert [{GobusgoWeb.Endpoint, pid, :supervisor, _modules}] =
             Supervisor.which_children(Gobusgo.Supervisor)

    assert Process.alive?(pid)
  end
end
