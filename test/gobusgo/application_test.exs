defmodule Gobusgo.ApplicationTest do
  # Verifies the application boots: its supervisor and the children the
  # supervisor starts are alive.
  use ExUnit.Case, async: true

  test "the supervision tree is running" do
    assert is_pid(Process.whereis(Gobusgo.Supervisor))
  end

  test "the supervisor runs the agency view and the HTTP endpoint" do
    children = Supervisor.which_children(Gobusgo.Supervisor)

    assert Enum.sort(for {id, pid, _type, _modules} <- children, is_pid(pid), do: id) ==
             [Gobusgo.OneBusAway.AgencyView, GobusgoWeb.Endpoint]
  end
end
