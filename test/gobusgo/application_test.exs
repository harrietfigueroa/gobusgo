defmodule Gobusgo.ApplicationTest do
  # Verifies the application boots: its supervisor and the children the
  # supervisor starts are alive, in the order they depend on each other, and
  # every topic a dataset publishes to reaches a subscriber in the application.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.AgencyBatch
  alias Gobusgo.OneBusAway.ArrivalBatch
  alias Gobusgo.OneBusAway.RawAgencyResponse
  alias Gobusgo.OneBusAway.RawArrivalResponse
  alias Gobusgo.OneBusAway.RawRouteScheduleResponse
  alias Gobusgo.OneBusAway.RawVehicleResponse
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RouteDatasets
  alias Gobusgo.OneBusAway.RoutePathBatch
  alias Gobusgo.OneBusAway.RouteScheduleBatch
  alias Gobusgo.OneBusAway.VehicleBatch

  defp subscribers do
    :gobusgo
    |> Application.fetch_env!(Gobusgo.Publisher.InProcess)
    |> Keyword.fetch!(:subscribers)
  end

  # Every topic a dataset publishes to, named by the module that owns it.
  for module <- [
        RawAgencyResponse.StoredEvent,
        RawVehicleResponse.StoredEvent,
        RouteDatasets,
        RawArrivalResponse.StoredEvent,
        RawRouteScheduleResponse.StoredEvent,
        AgencyBatch.Records,
        VehicleBatch.Records,
        RouteBatch.Records,
        RoutePathBatch.Records,
        RoutePathBatch.StopRecords,
        ArrivalBatch.Records,
        RouteScheduleBatch.Records
      ] do
    test "the topic of #{inspect(module)} has a subscriber" do
      assert Map.has_key?(subscribers(), unquote(module).topic())
    end
  end

  test "the route state topic hands its records to both route views" do
    assert subscribers()["oba.routes.state"] ==
             {Gobusgo.OneBusAway.FetchView, :apply_records_to_each,
              [[Gobusgo.OneBusAway.RouteView, Gobusgo.OneBusAway.RoutePathView]]}
  end

  test "the stop state topic hands its records to the stop view" do
    assert subscribers()["oba.stops.state"] ==
             {Gobusgo.OneBusAway.StopView, :apply_records, [Gobusgo.OneBusAway.StopView]}
  end

  test "the arrivals state topic hands its records to the arrivals view" do
    assert subscribers()["oba.arrivals.state"] ==
             {Gobusgo.OneBusAway.FetchView, :apply_records, [Gobusgo.OneBusAway.ArrivalView]}
  end

  test "the schedule state topic hands its records to the route schedule view" do
    assert subscribers()["oba.schedules.state"] ==
             {Gobusgo.OneBusAway.RouteScheduleView, :apply_records,
              [Gobusgo.OneBusAway.RouteScheduleView]}
  end

  test "the supervision tree is running" do
    assert is_pid(Process.whereis(Gobusgo.Supervisor))
  end

  test "the supervisor runs the publish-subscribe server, the views, the ingestion processes, the tile archive's holder, and the HTTP endpoint" do
    children = Supervisor.which_children(Gobusgo.Supervisor)

    # which_children/1 lists the children last started first.
    assert Enum.reverse(for {id, pid, _type, _modules} <- children, is_pid(pid), do: id) == [
             Phoenix.PubSub.Supervisor,
             Gobusgo.OneBusAway.AgencyView,
             Gobusgo.OneBusAway.VehicleView,
             Gobusgo.OneBusAway.RouteView,
             Gobusgo.OneBusAway.RoutePathView,
             Gobusgo.OneBusAway.StopView,
             Gobusgo.OneBusAway.RouteScheduleView,
             Gobusgo.OneBusAway.ArrivalView,
             Gobusgo.OneBusAway.VehicleSituationView,
             Gobusgo.OneBusAway.ArrivalSituationView,
             Gobusgo.Gbfs.VehicleTypeView,
             Gobusgo.Demand,
             Gobusgo.OneBusAway.RequestGate,
             Gobusgo.IngestionTaskSupervisor,
             GobusgoWeb.RouteStopTiles,
             Gobusgo.Routing.Snapshots,
             GobusgoWeb.Endpoint,
             Gobusgo.SchedulerSupervisor
           ]
  end

  test "no source and no cleanup is scheduled under test" do
    assert Supervisor.which_children(Gobusgo.SchedulerSupervisor) == []
  end
end
