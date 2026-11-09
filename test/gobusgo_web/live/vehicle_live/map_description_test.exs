defmodule GobusgoWeb.VehicleLive.MapDescriptionTest do
  # Checks the sentence that describes what the vehicle map's filter keeps,
  # by calling the pure function with literal filters, filter bar tokens,
  # and trips.
  use ExUnit.Case, async: true

  alias GobusgoWeb.VehicleLive.MapDescription

  @metro %{field: "agency", id: "1", name: "King County Metro"}
  @sound %{field: "agency", id: "40", name: "Sound Transit"}
  @rapid %{field: "route", id: "1_102576", name: "E Line"}
  @thirty_six %{field: "route", id: "1_100221", name: "36"}
  @link %{field: "route", id: "40_100479", name: "1 Line"}

  describe "filter_sentence/1" do
    test "a filter that names nothing keeps every agency" do
      assert MapDescription.filter_sentence(%{filter: %{}, tokens: [], trip: nil}) ==
               "It shows the vehicles, route lines, and stops of every agency."
    end

    test "a filter by one agency names it" do
      assert MapDescription.filter_sentence(%{
               filter: %{"agency" => ["1"]},
               tokens: [@metro],
               trip: nil
             }) ==
               "It shows the vehicles, route lines, and stops of King County Metro."
    end

    test "a filter by two agencies names both" do
      filter = %{"agency" => ["1", "40"]}

      assert MapDescription.filter_sentence(%{
               filter: filter,
               tokens: [@metro, @sound],
               trip: nil
             }) ==
               "It shows the vehicles, route lines, and stops of King County Metro and Sound Transit."
    end

    test "a filter by three routes names them in a list" do
      filter = %{"route" => ["1_102576", "1_100221", "40_100479"]}

      assert MapDescription.filter_sentence(%{
               filter: filter,
               tokens: [@rapid, @thirty_six, @link],
               trip: nil
             }) ==
               "It shows the vehicles, route lines, and stops of the routes E Line, 36, and 1 Line."
    end

    test "a filter by agency and route names the routes of the agency" do
      filter = %{"agency" => ["1"], "route" => ["1_102576"]}

      assert MapDescription.filter_sentence(%{
               filter: filter,
               tokens: [@metro, @rapid],
               trip: nil
             }) ==
               "It shows the vehicles, route lines, and stops of the route E Line of King County Metro."
    end

    test "a trip's filter names the trip's routes in riding order" do
      trip = %{route_ids: ["1_100221", "1_102576"]}

      assert MapDescription.filter_sentence(%{
               filter: %{},
               tokens: [@rapid, @thirty_six],
               trip: trip
             }) ==
               "It shows the vehicles, route lines, and stops of the trip's routes: 36 and E Line."
    end

    test "a trip's route the tokens do not name reads as its identifier" do
      trip = %{route_ids: ["1_999"]}

      assert MapDescription.filter_sentence(%{filter: %{}, tokens: [], trip: trip}) ==
               "It shows the vehicles, route lines, and stops of the trip's route: 1_999."
    end

    test "a refused filter shows nothing" do
      assert MapDescription.filter_sentence(%{filter: :refused, tokens: [], trip: nil}) ==
               "It shows nothing, because the filter in the address is not valid."
    end
  end
end
