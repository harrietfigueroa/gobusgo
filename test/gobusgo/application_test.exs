defmodule Gobusgo.ApplicationTest do
  # Verifies the application boots: its supervisor and the children the
  # supervisor starts are alive, in the order they depend on each other.
  use ExUnit.Case, async: true

  test "the supervision tree is running" do
    assert is_pid(Process.whereis(Gobusgo.Supervisor))
  end

  test "the supervisor runs the publish-subscribe server, the views, the ingestion processes, and the HTTP endpoint" do
    children = Supervisor.which_children(Gobusgo.Supervisor)

    # which_children/1 lists the children last started first.
    assert Enum.reverse(for {id, pid, _type, _modules} <- children, is_pid(pid), do: id) == [
             Phoenix.PubSub.Supervisor,
             Gobusgo.OneBusAway.AgencyView,
             Gobusgo.OneBusAway.VehicleView,
             Gobusgo.OneBusAway.RequestGate,
             Gobusgo.IngestionTaskSupervisor,
             Gobusgo.SchedulerSupervisor,
             GobusgoWeb.Endpoint
           ]
  end

  test "no source is scheduled under test" do
    assert Supervisor.which_children(Gobusgo.SchedulerSupervisor) == []
  end
end
