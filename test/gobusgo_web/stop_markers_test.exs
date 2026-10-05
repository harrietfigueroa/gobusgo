defmodule GobusgoWeb.StopMarkersTest do
  # Verifies what a map page draws for stops as pure functions of held stops
  # and route fetches written here in the form the views return them.
  use ExUnit.Case, async: true

  alias GobusgoWeb.StopMarkers

  defp held_stop(overrides \\ %{}) do
    stop =
      Map.merge(
        %{
          "id" => "1_75403",
          "name" => "East Stevens Way NE & Benton Ln",
          "lat" => 47.654503,
          "lon" => -122.30513,
          "code" => "75403",
          "direction" => "SW",
          "locationType" => 0,
          "parent" => nil,
          "wheelchairBoarding" => "ACCESSIBLE",
          "routeIds" => ["1_44", "1_45"]
        },
        overrides
      )

    %{
      id: stop["id"],
      request_id: "0199c4a2-7e1b-7a3f-9d20-000000000001",
      fetched_at: ~U[2026-10-05 01:00:00Z],
      stop: stop
    }
  end

  describe "route_names/1" do
    test "returns the short name of each route of every fetch" do
      route_fetches = [
        %{id: "1", routes: %{"1_44" => %{"shortName" => "44", "longName" => "Ballard"}}},
        %{id: "40", routes: %{"40_1" => %{"shortName" => "1 Line", "longName" => nil}}}
      ]

      assert StopMarkers.route_names(route_fetches) == %{"1_44" => "44", "40_1" => "1 Line"}
    end

    test "returns the long name of a route that has no short name" do
      route_fetches = [%{routes: %{"95_1" => %{"shortName" => nil, "longName" => "Ferry"}}}]

      assert StopMarkers.route_names(route_fetches) == %{"95_1" => "Ferry"}
    end

    test "leaves out a route that has neither name" do
      route_fetches = [%{routes: %{"95_1" => %{"shortName" => nil, "longName" => nil}}}]

      assert StopMarkers.route_names(route_fetches) == %{}
    end
  end

  describe "drawn?/1" do
    for {name, route_ids, drawn} <- [
          {"a stop one of whose routes is drawn", ["1_45"], true},
          {"a stop none of whose routes is drawn", ["1_7"], false},
          {"any stop when no route is drawn", [], false}
        ] do
      test "is #{drawn} for #{name}" do
        route_ids = MapSet.new(unquote(route_ids))

        assert StopMarkers.drawn?(%{held_stop: held_stop(), route_ids: route_ids}) ==
                 unquote(drawn)
      end
    end

    test "is false for a stop no route serves" do
      held_stop = held_stop(%{"routeIds" => []})

      refute StopMarkers.drawn?(%{held_stop: held_stop, route_ids: MapSet.new(["1_44"])})
    end
  end

  describe "marker/1" do
    test "holds the stop's position, texts, and the names of its routes in the stop's order" do
      route_names = %{"1_45" => "45", "1_44" => "44", "1_7" => "7"}

      assert StopMarkers.marker(%{held_stop: held_stop(), route_names: route_names}) == %{
               id: "1_75403",
               lat: 47.654503,
               lon: -122.30513,
               name: "East Stevens Way NE & Benton Ln",
               code: "75403",
               direction: "SW",
               routes: ["44", "45"]
             }
    end

    test "leaves out a route that has no name" do
      marker = StopMarkers.marker(%{held_stop: held_stop(), route_names: %{"1_45" => "45"}})

      assert marker.routes == ["45"]
    end

    test "holds no code and no direction for a stop that has none" do
      held_stop = held_stop(%{"code" => nil, "direction" => nil})

      assert %{code: nil, direction: nil} =
               StopMarkers.marker(%{held_stop: held_stop, route_names: %{}})
    end
  end

  describe "chunks/1" do
    test "splits the markers into lists of at most the event's bound" do
      markers = for index <- 1..(StopMarkers.event_stop_count_max() + 1), do: %{id: index}

      assert [first, [_last]] = StopMarkers.chunks(markers)
      assert length(first) == StopMarkers.event_stop_count_max()
    end

    test "returns no list for no marker" do
      assert StopMarkers.chunks([]) == []
    end
  end
end
