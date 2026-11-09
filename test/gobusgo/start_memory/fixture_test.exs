defmodule Gobusgo.StartMemory.FixtureTest do
  # Builds the synthetic network and the first responses of each dataset,
  # and reads them back through each dataset's own parser, so the fixture is
  # held to the stored form a start reads and to the sizes it stands in for.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.RawRoutePathResponse
  alias Gobusgo.OneBusAway.RawRouteResponse
  alias Gobusgo.OneBusAway.RawRouteScheduleResponse
  alias Gobusgo.StartMemory.Fixture

  @date ~D[2026-11-08]
  @agency_count 12
  @route_count 390
  @first_schedule_index @agency_count + @route_count

  describe "routes/0" do
    test "returns the same network on every call" do
      assert Fixture.routes() == Fixture.routes()
    end

    test "serves each stop of a route once" do
      repeated =
        for route <- Fixture.routes(),
            length(Enum.uniq(route.stop_cells)) != length(route.stop_cells),
            do: route.id

      assert repeated == []
    end
  end

  describe "summary/1" do
    setup do
      %{summary: Fixture.summary(@date)}
    end

    test "names production's counts of agencies and routes", %{summary: summary} do
      assert {summary.agency_count, summary.route_count} == {@agency_count, @route_count}
    end

    test "holds the schedules of 629 routes over the date and the day after", %{summary: summary} do
      assert for(schedule <- summary.schedules, do: {schedule.service_date, schedule.route_count}) ==
               [{~D[2026-11-08], 290}, {~D[2026-11-09], 339}]
    end

    test "gives each date's own trips about 440,000 and 650,000 connections", %{summary: summary} do
      [first, second] = summary.schedules
      assert_in_delta first.connection_count, 440_000, 4_400
      assert_in_delta second.connection_count, 650_000, 6_500
    end

    test "spreads the routes over more than 10,000 stops", %{summary: summary} do
      assert summary.stop_count > 10_000
    end
  end

  describe "responses/1" do
    test "stores each agency's routes as the route recorder does" do
      response = @date |> Fixture.responses() |> Enum.at(0)
      assert {:ok, %{agency_id: "1"}} = RawRouteResponse.parse(stored(response))
    end

    test "stores each route's stops and path as the route path recorder does" do
      response = @date |> Fixture.responses() |> Enum.at(@agency_count)
      assert {:ok, %{route_id: "1_100000"}} = RawRoutePathResponse.parse(stored(response))
    end

    test "stores each schedule under the service date it holds, fetched on the date" do
      response = @date |> Fixture.responses() |> Enum.at(@first_schedule_index)
      assert {:ok, parsed} = RawRouteScheduleResponse.parse(stored(response))
      assert {parsed.service_date, DateTime.to_date(parsed.fetched_at)} == {@date, @date}
    end

    test "builds the same content for the same date" do
      first = @date |> Fixture.responses() |> Enum.at(@first_schedule_index)
      second = @date |> Fixture.responses() |> Enum.at(@first_schedule_index)
      assert first == second
    end

    test "writes every response of the date under that fetch date" do
      prefixes =
        @date
        |> Fixture.responses()
        |> Enum.take(@first_schedule_index)
        |> Enum.map(&(&1.destination |> String.split("/") |> Enum.at(3)))
        |> Enum.uniq()

      assert prefixes == ["dt=2026-11-08"]
    end
  end

  defp stored(response), do: %{destination: response.destination, content: response.content}
end
