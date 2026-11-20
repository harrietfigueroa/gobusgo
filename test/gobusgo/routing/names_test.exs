defmodule Gobusgo.Routing.NamesTest do
  # Verifies the names file as a pure function of names written out by
  # hand: what it holds by index and by identifier, that it encodes to the
  # shared fixture's content byte for byte, and which files decode/1
  # refuses.
  use ExUnit.Case, async: true

  alias Gobusgo.Compression
  alias Gobusgo.OneBusAway.CompactSchedule
  alias Gobusgo.Routing.Names
  alias Gobusgo.Test.RoutingNamesFixture

  defp built, do: Names.build(RoutingNamesFixture.input())

  defp fixture_content do
    stream = File.read!(Path.join(RoutingNamesFixture.directory(), "names.json.gz"))
    {:ok, content} = Compression.decompress(stream, Compression.content_bytes_max())
    content
  end

  test "holds each stop's name and code in the order of the stops file" do
    assert {built()["stopNames"], built()["stopCodes"]} ==
             {["3rd Ave & Pike St", nil, "Café Ünïcode Transit Center"], ["1100", nil, nil]}
  end

  test "holds each trip's headsign in the order of the trips file, by run" do
    assert built()["tripHeadsigns"] == ["Downtown Seattle", nil, "Othello Station"]
  end

  test "takes a trip's headsign from the listing that owns it, whatever order the schedules come in" do
    listing = fn route_id, headsign ->
      {:ok, compact} =
        CompactSchedule.pack(%{
          route_id: route_id,
          schedule_date_ms: 0,
          service_ids: ["s"],
          stop_ids: ["1_A", "1_B"],
          trips: [
            %{
              id: "t1",
              route_id: "1_B",
              direction_id: "0",
              headsign: headsign,
              block_id: nil,
              service_id: "s",
              shape_id: nil,
              stop_indexes: [0, 1],
              arrival_s: [100, 200],
              departure_s: [100, 200],
              arrival_enabled: [true, true],
              departure_enabled: [true, true]
            }
          ]
        })

      compact
    end

    schedules = [listing.("1_A", "From A"), listing.("1_B", "From B")]

    forward = Names.headsigns(%{schedules: schedules, previous_schedules: []})
    backward = Names.headsigns(%{schedules: Enum.reverse(schedules), previous_schedules: []})

    assert {forward, backward} == {%{{0, "t1"} => "From B"}, %{{0, "t1"} => "From B"}}
  end

  test "holds the routes the trips name and the names of their agencies" do
    assert {Map.keys(built()["routes"]), built()["agencyNames"]} ==
             {["1_100479", "29_7"], %{"1" => "Metro Transit"}}
  end

  test "encodes to the shared fixture's content byte for byte" do
    assert Names.encode(built()) == fixture_content()
  end

  test "decodes the shared fixture to the names the JavaScript reader returns" do
    {:ok, names} = Names.decode(fixture_content())
    assert Map.delete(names, "version") == RoutingNamesFixture.expected()
  end

  test "takes each trip's headsign from its own service date's schedule" do
    schedule = fn trips ->
      %{
        route_id: "1_R",
        trips:
          Enum.map(trips, fn {id, headsign} ->
            %{id: id, route_id: nil, headsign: headsign}
          end)
      }
    end

    assert Names.headsigns(%{
             schedules: [schedule.([{"t", "North"}])],
             previous_schedules: [schedule.([{"t", "South"}])]
           }) == %{{0, "t"} => "North", {1, "t"} => "South"}
  end

  for {label, content, reason} <- [
        {"not JSON", "{", :invalid_json},
        {"of another version", ~s({"version":2}), :unsupported_version},
        {"without a version", ~s([]), :schema_mismatch},
        {"with a column of another shape",
         ~s({"version":1,"stopNames":[1],"stopCodes":[null],"tripHeadsigns":[],"routes":{},"agencyNames":{}}),
         :schema_mismatch},
        {"with columns of different lengths",
         ~s({"version":1,"stopNames":["a"],"stopCodes":[],"tripHeadsigns":[],"routes":{},"agencyNames":{}}),
         :schema_mismatch},
        {"with a route of another shape",
         ~s({"version":1,"stopNames":[],"stopCodes":[],"tripHeadsigns":[],"routes":{"r":{}},"agencyNames":{}}),
         :schema_mismatch},
        {"with an agency name that is not text",
         ~s({"version":1,"stopNames":[],"stopCodes":[],"tripHeadsigns":[],"routes":{},"agencyNames":{"1":7}}),
         :schema_mismatch}
      ] do
    test "refuses a file #{label}" do
      assert Names.decode(unquote(content)) == {:error, unquote(reason)}
    end
  end
end
