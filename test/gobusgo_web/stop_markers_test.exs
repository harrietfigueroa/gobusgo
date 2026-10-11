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

  defp marker(overrides) do
    StopMarkers.marker(
      Map.merge(%{held_stop: held_stop(), route_names: %{}, route_agency_names: %{}}, overrides)
    )
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

  describe "route_agency_names/1" do
    test "returns the name of the agency of each route of every fetch" do
      route_fetches = [
        %{routes: %{"1_44" => %{"agencyId" => "1"}, "1_45" => %{"agencyId" => "1"}}},
        %{routes: %{"40_1" => %{"agencyId" => "40"}}}
      ]

      agency_names = %{"1" => "Metro Transit", "40" => "Sound Transit"}

      assert StopMarkers.route_agency_names(%{
               route_fetches: route_fetches,
               agency_names: agency_names
             }) == %{
               "1_44" => "Metro Transit",
               "1_45" => "Metro Transit",
               "40_1" => "Sound Transit"
             }
    end

    test "leaves out a route whose agency has no name" do
      route_fetches = [%{routes: %{"95_1" => %{"agencyId" => "95"}}}]

      assert StopMarkers.route_agency_names(%{
               route_fetches: route_fetches,
               agency_names: %{"1" => "Metro Transit"}
             }) == %{}
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

      assert marker(%{route_names: route_names}) == %{
               id: "1_75403",
               lat: 47.654503,
               lon: -122.30513,
               name: "East Stevens Way NE & Benton Ln",
               code: "75403",
               direction: "SW",
               routes: ["44", "45"],
               agencies: []
             }
    end

    test "leaves out a route that has no name" do
      assert marker(%{route_names: %{"1_45" => "45"}}).routes == ["45"]
    end

    test "holds the name of each agency of its routes once, in the stop's order of routes" do
      held_stop = held_stop(%{"routeIds" => ["40_1", "1_44", "1_45"]})

      route_agency_names = %{
        "1_44" => "Metro Transit",
        "1_45" => "Metro Transit",
        "40_1" => "Sound Transit"
      }

      marker = marker(%{held_stop: held_stop, route_agency_names: route_agency_names})

      assert marker.agencies == ["Sound Transit", "Metro Transit"]
    end

    test "leaves out the agency of a route that has no agency name" do
      assert marker(%{route_agency_names: %{"1_45" => "Metro Transit"}}).agencies ==
               ["Metro Transit"]
    end

    test "holds no code and no direction for a stop that has none" do
      held_stop = held_stop(%{"code" => nil, "direction" => nil})

      assert %{code: nil, direction: nil} = marker(%{held_stop: held_stop})
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
