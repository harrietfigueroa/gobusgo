defmodule Gobusgo.OneBusAway.SituationsTest do
  # Parses the situations of a response's references, cut from live
  # responses of 2026-10-15, and alters one field at a time to check that a
  # situation breaking a rule is rejected alone. Then checks that the
  # published form of a situation reads back to the same value.
  use ExUnit.Case, async: true

  alias Gobusgo.OneBusAway.Situations

  @fixture_path Path.expand("../../fixtures/one_bus_away/situations.json", __DIR__)

  defp data, do: @fixture_path |> File.read!() |> JSON.decode!()

  defp source_situations, do: get_in(data(), ["references", "situations"])

  defp with_situations(situations), do: %{"references" => %{"situations" => situations}}

  defp parse_one(changes) do
    [first | _rest] = source_situations()
    Situations.parse(with_situations([Map.merge(first, changes)]))
  end

  describe "parse/1" do
    test "reads every situation of the fixture" do
      assert %{situations: situations, rejected_count: 0} = Situations.parse(data())

      assert Enum.map(situations, & &1.id) == [
               "40_21008",
               "1_96631",
               "3_988f57b4-6736-498d-908f-b172bd6d47f4",
               "29_74873"
             ]
    end

    test "reads the texts, the trimmed link, the reason, and the creation time" do
      %{situations: [situation | _rest]} = Situations.parse(data())

      assert situation.summary =~ "Link shuttle buses will replace 2 Line trains"
      assert situation.description =~ "Please plan ahead for additional travel time."

      assert situation.url ==
               "https://www.soundtransit.org/ride-with-us/changes-affect-my-ride/planned-service-disruptions"

      assert situation.reason == "MAINTENANCE"
      assert situation.creation_time_ms == 1_792_080_593_599
    end

    test "reads a window with both ends, one with no end, and no window" do
      %{situations: [closed, open_ended, unbounded, _stop_scoped]} = Situations.parse(data())

      assert closed.active_windows == [%{from_ms: 1_792_231_200_000, to_ms: 1_792_402_200_000}]
      assert open_ended.active_windows == [%{from_ms: 1_791_899_580_000, to_ms: nil}]
      assert unbounded.active_windows == []
    end

    test "reads a route-wide affect and affects of a route at stops" do
      %{situations: [closed, _open_ended, _unbounded, stop_scoped]} = Situations.parse(data())

      assert closed.affects == [%{agency_id: "40", route_id: "40_2LINE", stop_id: nil}]

      assert stop_scoped.affects == [
               %{agency_id: "40", route_id: "40_532", stop_id: "29_355"},
               %{agency_id: "40", route_id: "40_532", stop_id: "1_67655"}
             ]
    end

    test "reads no situation from references that hold none" do
      assert Situations.parse(%{"references" => %{"trips" => []}}) ==
               %{situations: [], rejected_count: 0}

      assert Situations.parse(%{}) == %{situations: [], rejected_count: 0}
    end

    test "reads an absent text, link, reason, and creation time as nil" do
      %{situations: [situation], rejected_count: 0} =
        parse_one(%{"description" => nil, "url" => nil, "reason" => "", "creationTime" => nil})

      assert situation.description == nil
      assert situation.url == nil
      assert situation.reason == nil
      assert situation.creation_time_ms == nil
    end

    test "reads a window start or end of zero as none" do
      %{situations: [situation]} = parse_one(%{"activeWindows" => [%{"from" => 0, "to" => 0}]})

      assert situation.active_windows == [%{from_ms: nil, to_ms: nil}]
    end

    test "leaves out an affect that names nothing" do
      %{situations: [situation]} =
        parse_one(%{"allAffects" => [%{"agencyId" => "", "routeId" => "", "stopId" => ""}]})

      assert situation.affects == []
    end

    for {name, url} <- [
          {"not http", "javascript:alert(1)"},
          {"no host", "https://"},
          {"not a link", "plan ahead"}
        ] do
      test "reads a link that is #{name} as none" do
        %{situations: [situation]} = parse_one(%{"url" => %{"value" => unquote(url)}})

        assert situation.url == nil
      end
    end

    for {name, changes} <- [
          {"an empty identifier", %{"id" => ""}},
          {"an identifier that is no string", %{"id" => 7}},
          {"no summary", %{"summary" => nil}},
          {"a blank summary", %{"summary" => %{"value" => "  "}}},
          {"a window that ends before it starts",
           %{"activeWindows" => [%{"from" => 2_000, "to" => 1_000}]}},
          {"a window time that is no integer", %{"activeWindows" => [%{"from" => "soon"}]}},
          {"affects that are no list", %{"allAffects" => %{}}},
          {"a summary over the bound",
           %{"summary" => %{"value" => String.duplicate("a", 1_001)}}},
          {"a description over the bound",
           %{"description" => %{"value" => String.duplicate("a", 10_001)}}}
        ] do
      test "rejects a situation with #{name} and keeps the others" do
        [first | rest] = source_situations()
        situations = [Map.merge(first, unquote(Macro.escape(changes))) | rest]

        assert %{situations: kept, rejected_count: 1} =
                 Situations.parse(with_situations(situations))

        assert length(kept) == length(rest)
      end
    end

    test "rejects a situation whose identifier repeats an earlier one" do
      [first | _rest] = source_situations()

      assert %{situations: [kept], rejected_count: 1} =
               Situations.parse(with_situations([first, first]))

      assert kept.id == first["id"]
    end

    test "rejects the situations beyond the bound of a response" do
      [first | _rest] = source_situations()
      count = Situations.situation_count_max() + 2
      situations = for index <- 1..count, do: Map.put(first, "id", "id-#{index}")

      assert %{situations: kept, rejected_count: 2} =
               Situations.parse(with_situations(situations))

      assert length(kept) == Situations.situation_count_max()
    end

    test "rejects every situation of situations that are no list" do
      assert Situations.parse(%{"references" => %{"situations" => %{}}}) ==
               %{situations: [], rejected_count: 1}
    end
  end

  describe "to_data/1 and from_data/1" do
    test "read back every situation of the fixture as it was" do
      %{situations: situations} = Situations.parse(data())

      for situation <- situations do
        assert situation |> Situations.to_data() |> Situations.from_data() == situation
      end
    end

    test "hold a situation in the published fields" do
      %{situations: [situation | _rest]} = Situations.parse(data())

      assert Situations.to_data(situation) |> Map.keys() |> Enum.sort() ==
               ~w(activeWindows affects creationTimeMs description id reason summary url)
    end
  end
end
