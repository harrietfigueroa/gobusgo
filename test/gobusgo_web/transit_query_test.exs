defmodule GobusgoWeb.TransitQueryTest do
  # Reads the application's global views, which the test fills with
  # Gobusgo.Test.TransitSeeds and restarts around each case, hence the
  # non-async case. Each case states what it seeds and what the query
  # answers; the vehicle page's own tests cover the same computations
  # through the page.
  use ExUnit.Case, async: false

  @moduletag capture_log: true

  alias Gobusgo.Test.TransitSeeds
  alias GobusgoWeb.TransitQuery

  setup do
    TransitSeeds.restart_views()
    on_exit(&TransitSeeds.restart_views/0)
  end

  defp seed_names do
    :ok = TransitSeeds.agencies([{"40", "Sound Transit"}, {"1", "Metro Transit"}])

    :ok =
      TransitSeeds.routes("1", [
        {"1_100", "8", "Seattle Center - Capitol Hill"},
        {"1_200", "40", "Northgate - Ballard"}
      ])
  end

  describe "agencies/0" do
    test "is empty before the agency view has a fetch" do
      assert TransitQuery.agencies() == []
    end

    test "gives each agency its identifier and name in the view's order" do
      seed_names()

      assert TransitQuery.agencies() == [
               %{id: "1", name: "Metro Transit"},
               %{id: "40", name: "Sound Transit"}
             ]
    end
  end

  describe "find/1" do
    test "is unavailable before the agency view has a fetch" do
      assert TransitQuery.find("metro") == :unavailable
    end

    test "answers the agencies and routes the filter bar suggests for the same text" do
      seed_names()
      bar = TransitQuery.filter_bar(filter_bar_input("40"))

      assert {:ok, found} = TransitQuery.find("40")

      assert found.agencies ++ found.routes == bar.suggestions
      assert found.rest_count == bar.rest_count
    end

    test "splits the suggestions by their field" do
      seed_names()

      assert {:ok, %{agencies: [%{field: "agency", id: "1"}], routes: []}} =
               TransitQuery.find("metro")

      assert {:ok, %{agencies: [], routes: [%{field: "route", id: "1_100"}]}} =
               TransitQuery.find("8")
    end

    test "names the agency fetch it draws on" do
      seed_names()

      assert {:ok, %{fetch: %{request_id: request_id, fetched_at: %DateTime{}}}} =
               TransitQuery.find("metro")

      assert is_binary(request_id)
    end

    test "finds a stop by a part of its name, those that start with the text first" do
      seed_names()

      :ok =
        TransitSeeds.stops("1_100", [
          {"1_3", "Capitol Hill Station", "300"},
          {"1_1", "Broadway and Pine", nil},
          {"1_2", "Pine Street", "200"}
        ])

      assert {:ok, %{stops: stops}} = TransitQuery.find("pine")
      assert Enum.map(stops, & &1.id) == ["1_2", "1_1"]
    end

    test "finds a stop by its code" do
      seed_names()
      :ok = TransitSeeds.stops("1_100", [{"1_3", "Capitol Hill Station", "300"}])

      assert {:ok, %{stops: [%{id: "1_3", code: "300", direction: "N", lat: 47.6}]}} =
               TransitQuery.find("300")
    end

    test "finds no stop for a code that is only part of another code" do
      seed_names()
      :ok = TransitSeeds.stops("1_100", [{"1_3", "Capitol Hill Station", "300"}])

      assert {:ok, %{stops: []}} = TransitQuery.find("30")
    end

    test "finds nothing for blank text" do
      seed_names()
      :ok = TransitSeeds.stops("1_100", [{"1_3", "Capitol Hill Station", "300"}])

      assert {:ok, %{agencies: [], routes: [], stops: [], stop_rest_count: 0}} =
               TransitQuery.find("   ")
    end

    test "holds at most the stop bound and counts the rest" do
      seed_names()
      stop_count = TransitQuery.stop_count_max() + 5
      stops = for number <- 1..stop_count, do: {"1_s#{number}", "Stop #{number}", nil}
      :ok = TransitSeeds.stops("1_100", stops)

      assert {:ok, %{stops: kept, stop_rest_count: 5}} = TransitQuery.find("stop")
      assert length(kept) == TransitQuery.stop_count_max()
    end
  end

  describe "find_version/0" do
    test "changes when a newer fetch of the agencies arrives" do
      seed_names()
      before = TransitQuery.find_version()

      :ok = TransitSeeds.agencies([{"1", "Metro Transit"}])

      assert TransitQuery.find_version() != before
    end

    test "changes when a newer fetch of the stops arrives" do
      seed_names()
      :ok = TransitSeeds.stops("1_100", [{"1_3", "Capitol Hill Station", nil}])
      before = TransitQuery.find_version()

      :ok = TransitSeeds.stops("1_100", [{"1_3", "Capitol Hill Station", nil}])

      assert TransitQuery.find_version() != before
    end

    test "holds while no fetch arrives" do
      seed_names()

      assert TransitQuery.find_version() == TransitQuery.find_version()
    end
  end

  describe "vehicles/1" do
    test "is unavailable while the vehicle view holds no fetch" do
      assert TransitQuery.vehicles(%{}) == :unavailable
    end

    test "gives the markers of every agency under no filter, in agency order" do
      :ok = TransitSeeds.vehicles("40", [{"40_x", "40_500"}])
      :ok = TransitSeeds.vehicles("1", [{"1_a", "1_100"}, {"1_b", nil}])

      assert {:ok, %{markers: markers, fetches: fetches}} = TransitQuery.vehicles(%{})

      assert Enum.map(markers, fn {agency_id, marker} -> {agency_id, marker.vehicle_id} end) ==
               [{"1", "1_a"}, {"1", "1_b"}, {"40", "40_x"}]

      assert Enum.map(fetches, & &1.agency_id) == ["1", "40"]
    end

    test "keeps the vehicles of the agencies and routes the filter names" do
      :ok = TransitSeeds.vehicles("1", [{"1_a", "1_100"}, {"1_b", "1_200"}, {"1_c", nil}])
      :ok = TransitSeeds.vehicles("40", [{"40_x", "40_500"}])

      assert {:ok, %{markers: [{"1", %{vehicle_id: "1_a"}}], fetches: [%{agency_id: "1"}]}} =
               TransitQuery.vehicles(%{"agency" => ["1"], "route" => ["1_100"]})
    end

    test "answers no marker and no fetch for a filter that keeps no agency with a fetch" do
      :ok = TransitSeeds.vehicles("1", [{"1_a", "1_100"}])

      assert {:ok, %{markers: [], fetches: []}} = TransitQuery.vehicles(%{"agency" => ["95"]})
    end
  end

  describe "stop_answer/1" do
    test "waits for a stop with no fetch" do
      assert %{shown: %{stop_id: "1_1", status: :waiting}, fetch: nil} =
               TransitQuery.stop_answer("1_1")
    end

    test "shows the arrivals of the stop's fetch, soonest first, with the fetch" do
      :ok = TransitSeeds.arrivals("1_1", [{"late", 20}, {"soon", 5}])

      assert %{
               shown: %{status: :arrivals, arrivals: [%{trip_id: "soon"}, %{trip_id: "late"}]},
               fetch: %{request_id: request_id}
             } = TransitQuery.stop_answer("1_1")

      assert is_binary(request_id)
    end

    test "is the answer stop_arrivals/1 gives" do
      :ok = TransitSeeds.arrivals("1_1", [{"soon", 5}])

      assert %{shown: shown} = TransitQuery.stop_answer("1_1")
      assert TransitQuery.stop_arrivals("1_1") == shown
    end
  end

  describe "arrivals_version/1" do
    test "changes when the stop's fetch changes and holds otherwise" do
      :ok = TransitSeeds.arrivals("1_1", [{"soon", 5}])
      before = TransitQuery.arrivals_version("1_1")
      assert TransitQuery.arrivals_version("1_1") == before

      :ok = TransitSeeds.arrivals("1_1", [{"soon", 5}])

      assert TransitQuery.arrivals_version("1_1") != before
    end
  end

  describe "stop_known?/1" do
    test "is true for a stop of the stop view only" do
      :ok = TransitSeeds.stops("1_100", [{"1_3", "Capitol Hill Station", nil}])

      assert TransitQuery.stop_known?("1_3")
      refute TransitQuery.stop_known?("1_4")
    end
  end

  defp filter_bar_input(query) do
    %{
      filter: %{},
      query: query,
      agencies: TransitQuery.agencies(),
      route_fetches: TransitQuery.route_fetches()
    }
  end
end
