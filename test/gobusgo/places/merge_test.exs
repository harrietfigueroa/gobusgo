defmodule Gobusgo.Places.MergeTest do
  # Drives the merge over hand-built candidates placed at known distances:
  # 0.001 degrees of latitude is about 111 m.
  use ExUnit.Case, async: true

  alias Gobusgo.Places.Merge

  defp candidate(changes) do
    Map.merge(
      %{
        name: "Cafe",
        aliases: [],
        lat: 47.5,
        lon: -122.3,
        category: "food",
        prominence: 50,
        area: 0.0,
        area_score: 0
      },
      Map.new(changes)
    )
  end

  defp north(meters), do: 47.5 + meters / 111_194.93

  describe "run/1" do
    test "merges two of one name under 150 m apart into the more prominent" do
      near = candidate(name: "Cafe", lat: north(120), prominence: 40)
      kept = candidate(name: "Cafe", prominence: 60)

      assert %{places: [place], merged_count: 1} = Merge.run([near, kept])
      assert place.prominence == 60
      assert place.lat == 47.5
    end

    test "keeps two of one name 150 m or more apart" do
      far = candidate(lat: north(160))
      assert %{places: [_, _], merged_count: 0} = Merge.run([candidate([]), far])
    end

    test "merges at under 300 m when one is a building" do
      building = candidate(lat: north(250), category: "building", prominence: 30)
      assert %{places: [_], merged_count: 1} = Merge.run([candidate([]), building])
    end

    test "merges a building with a station at 250 m" do
      building = candidate(category: "building", prominence: 30)
      station = candidate(lat: north(250), category: "station", prominence: 140)
      assert %{places: [place], merged_count: 1} = Merge.run([building, station])
      assert place.category == "station"
    end

    test "keeps a park and a station of one name 200 m apart" do
      park = candidate(category: "park", prominence: 135)
      station = candidate(lat: north(200), category: "station", prominence: 140)
      assert %{places: [_, _], merged_count: 0} = Merge.run([park, station])
    end

    test "keeps a building 300 m or more away" do
      building = candidate(lat: north(320), category: "building")
      assert %{places: [_, _]} = Merge.run([candidate([]), building])
    end

    test "compares names by their normalized words" do
      other = candidate(name: "CAFÉ", lat: north(50), prominence: 10)
      assert %{places: [_], merged_count: 1} = Merge.run([candidate([]), other])
    end

    test "keeps two names that differ" do
      other = candidate(name: "Tea House", lat: north(10))
      assert %{places: [_, _]} = Merge.run([candidate([]), other])
    end

    test "keeps the larger park over a more prominent station of one name" do
      park = candidate(category: "park", prominence: 135, area_score: 20)

      station =
        candidate(category: "station", prominence: 140, lat: north(100), aliases: ["Monorail"])

      assert %{places: [place], merged_count: 1} = Merge.run([station, park])
      assert place.category == "park"
      assert place.aliases == ["Monorail"]
    end

    test "gives the kept place the aliases of the merged one" do
      kept = candidate(aliases: ["A"], prominence: 60)
      merged = candidate(aliases: ["A", "B"], prominence: 10, lat: north(10))

      assert %{places: [%{aliases: ["A", "B"]}]} = Merge.run([merged, kept])
    end

    test "gives the same result whatever the input order" do
      candidates = [
        candidate(name: "B", prominence: 50),
        candidate(name: "A", prominence: 50, lat: north(500)),
        candidate(name: "A", prominence: 50, lat: north(520)),
        candidate(name: "C", category: "park", prominence: 50)
      ]

      assert Merge.run(candidates) == Merge.run(Enum.reverse(candidates))
    end

    test "orders places by category, then name" do
      candidates = [
        candidate(name: "Zed", category: "food"),
        candidate(name: "Ada", category: "park"),
        candidate(name: "Bob", category: "food"),
        candidate(name: "Cy", category: "station")
      ]

      assert %{places: places} = Merge.run(candidates)
      assert Enum.map(places, & &1.name) == ["Cy", "Ada", "Bob", "Zed"]
    end
  end
end
