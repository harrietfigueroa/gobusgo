defmodule Gobusgo.ApplicationTest do
  # Verifies the application boots: its supervisor and the children the
  # supervisor starts are alive, in the order they depend on each other.
  use ExUnit.Case, async: true

  test "one subscriber reads the route state topic and hands its records to both route views" do
    subscribers = Gobusgo.Application.topic_subscribers()

    assert [route_state] = Enum.filter(subscribers, &(&1.topic == "oba.routes.state"))

    assert route_state.subscriber ==
             {Gobusgo.OneBusAway.FetchView, :apply_records_to_each,
              [[Gobusgo.OneBusAway.RouteView, Gobusgo.OneBusAway.RoutePathView]]}
  end

  test "one subscriber reads the stop state topic and hands its records to the stop view" do
    subscribers = Gobusgo.Application.topic_subscribers()

    assert [stop_state] = Enum.filter(subscribers, &(&1.topic == "oba.stops.state"))

    assert stop_state.subscriber ==
             {Gobusgo.OneBusAway.StopView, :apply_records, [Gobusgo.OneBusAway.StopView]}
  end

  test "no two topic subscribers read one topic" do
    topics = Enum.map(Gobusgo.Application.topic_subscribers(), & &1.topic)

    assert topics == Enum.uniq(topics)
  end

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
             Gobusgo.OneBusAway.RouteView,
             Gobusgo.OneBusAway.RoutePathView,
             Gobusgo.OneBusAway.StopView,
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
