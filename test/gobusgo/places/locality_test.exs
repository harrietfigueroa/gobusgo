defmodule Gobusgo.Places.LocalityTest do
  # Drives the locality assignment over hand-written candidates and anchors
  # near Seattle: an address wins, otherwise the nearest settlement names the
  # place, with its city where the two differ.
  use ExUnit.Case, async: true

  alias Gobusgo.Places.Locality

  defp candidate(overrides) do
    Map.merge(
      %{
        name: "Westlake Center",
        aliases: [],
        lat: 47.6113,
        lon: -122.3375,
        category: "shop",
        prominence: 100,
        area: 0.0,
        area_score: 0,
        address: "",
        settlement: ""
      },
      overrides
    )
  end

  defp settlement(name, kind, lat, lon),
    do: candidate(%{name: name, category: "place", settlement: kind, lat: lat, lon: lon})

  defp localities(places, anchors) do
    for place <- Locality.assign(places, Locality.anchors(anchors)), do: place.locality
  end

  defp denny, do: settlement("Denny Triangle", "neighbourhood", 47.6180, -122.3360)
  defp seattle, do: settlement("Seattle", "city", 47.6038, -122.3301)
  defp bellevue, do: settlement("Bellevue", "city", 47.6101, -122.2015)

  describe "assign/2" do
    test "a tagged street address is the locality, over any settlement" do
      place = candidate(%{address: "400 Pine Street"})
      assert localities([place], [denny(), seattle()]) == ["400 Pine Street"]
    end

    test "the nearest neighborhood is named with its city" do
      assert localities([candidate(%{})], [denny(), seattle()]) == ["Denny Triangle, Seattle"]
    end

    test "a neighborhood in a city of its own name is named once" do
      same = settlement("Seattle", "suburb", 47.6180, -122.3360)
      assert localities([candidate(%{})], [same, seattle()]) == ["Seattle"]
    end

    test "a neighborhood with no city in range is named alone" do
      assert localities([candidate(%{})], [denny()]) == ["Denny Triangle"]
    end

    test "a city nearer than any neighborhood is the whole locality" do
      far_neighborhood = settlement("Ballard", "neighbourhood", 47.6680, -122.3840)
      assert localities([candidate(%{})], [far_neighborhood, seattle()]) == ["Seattle"]
    end

    test "settlements beyond the radius name nothing" do
      assert localities([candidate(%{})], [bellevue()]) == [""]
    end

    test "a settlement never names itself" do
      assert localities([denny()], [denny(), seattle()]) == ["Seattle"]
    end

    test "only a place of a settlement kind is an anchor" do
      village = settlement("Hamlet", "village", 47.6114, -122.3376)
      assert localities([candidate(%{})], [village]) == [""]
    end

    test "a nearer settlement beats a farther one" do
      near = settlement("Near", "neighbourhood", 47.6115, -122.3375)
      far = settlement("Far", "neighbourhood", 47.6200, -122.3375)
      assert localities([candidate(%{})], [far, near]) == ["Near"]
    end

    test "a locality is cut to the bound" do
      long = String.duplicate("a", Locality.length_max() + 20)
      [bounded] = localities([candidate(%{address: long})], [])
      assert String.length(bounded) == Locality.length_max()
    end
  end

  describe "address/1" do
    test "needs both a house number and a street" do
      assert Locality.address(%{"addr:housenumber" => "400", "addr:street" => "Pine St"}) ==
               "400 Pine St"

      assert Locality.address(%{"addr:street" => "Pine St"}) == ""
      assert Locality.address(%{"addr:housenumber" => "400"}) == ""
      assert Locality.address(%{"addr:housenumber" => " ", "addr:street" => "Pine St"}) == ""
    end

    test "replaces control characters and semicolons" do
      assert Locality.address(%{"addr:housenumber" => "4;5", "addr:street" => "Pine\nSt"}) ==
               "4 5 Pine St"
    end
  end
end
