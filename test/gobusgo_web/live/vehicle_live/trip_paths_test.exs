defmodule GobusgoWeb.VehicleLive.TripPathsTest do
  # Verifies what the vehicle page reads from a trip paths request and what
  # it sends back, as pure functions: each refused case starts from a valid
  # request with one field changed, so the test names the field that breaks
  # it.
  use ExUnit.Case, async: true

  alias GobusgoWeb.VehicleLive.TripPaths

  @service_date_ms 1_794_211_200_000

  defp trip(overrides \\ %{}) do
    Map.merge(
      %{"trip_id" => "1_1137791", "route_id" => "1_7994", "service_date_ms" => @service_date_ms},
      overrides
    )
  end

  describe "request/1" do
    test "reads each trip's identifier, route, and service date" do
      assert TripPaths.request(%{"trips" => [trip()]}) == [
               %{trip_id: "1_1137791", route_id: "1_7994", service_date_ms: @service_date_ms}
             ]
    end

    test "reads as many trips as one request takes" do
      trips = for index <- 1..TripPaths.trip_count_max(), do: trip(%{"trip_id" => "#{index}"})

      assert length(TripPaths.request(%{"trips" => trips})) == TripPaths.trip_count_max()
    end

    refused = [
      {"more trips than one request takes", :too_many},
      {"no trip", []},
      {"trips that are not a list", "1_1137791"},
      {"a trip with an empty identifier", [%{"trip_id" => ""}]},
      {"a trip whose route is not text", [%{"route_id" => 1}]},
      {"a trip whose service date is text", [%{"service_date_ms" => "2026-11-09"}]},
      {"a trip whose service date is a fraction", [%{"service_date_ms" => 1.5}]},
      {"a trip with no service date", [:no_service_date]}
    ]

    for {description, trips} <- refused do
      @trips trips
      test "refuses #{description}" do
        trips =
          case @trips do
            :too_many ->
              for index <- 0..TripPaths.trip_count_max(), do: trip(%{"trip_id" => "#{index}"})

            [:no_service_date] ->
              [Map.delete(trip(), "service_date_ms")]

            [overrides] when is_map(overrides) ->
              [trip(overrides)]

            other ->
              other
          end

        assert TripPaths.request(%{"trips" => trips}) == :refused
      end
    end

    test "refuses parameters that hold no trips" do
      assert TripPaths.request(%{}) == :refused
    end
  end

  describe "event/1" do
    test "sends each path and each trip without one, with its reason as text" do
      served = %{
        paths: [
          %{
            trip_id: "1_1137791",
            route_id: "1_7994",
            service_date_ms: @service_date_ms,
            points: "_p~iF~ps|U",
            stops: "???"
          }
        ],
        missing: [
          %{
            trip_id: "1_1137792",
            route_id: "1_7994",
            service_date_ms: @service_date_ms,
            reason: :stop_positions_missing
          }
        ]
      }

      assert TripPaths.event(served) == %{
               paths: [
                 %{
                   trip_id: "1_1137791",
                   route_id: "1_7994",
                   service_date_ms: @service_date_ms,
                   points: "_p~iF~ps|U",
                   stops: "???"
                 }
               ],
               missing: [
                 %{
                   trip_id: "1_1137792",
                   route_id: "1_7994",
                   service_date_ms: @service_date_ms,
                   reason: "stop_positions_missing"
                 }
               ]
             }
    end
  end

  describe "failed_event/1" do
    test "sends no path and the reason the request was not served" do
      assert TripPaths.failed_event(:busy) == %{paths: [], missing: [], failed: "busy"}
    end
  end
end
