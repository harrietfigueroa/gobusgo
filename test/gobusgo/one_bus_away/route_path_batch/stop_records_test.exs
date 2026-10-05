defmodule Gobusgo.OneBusAway.RoutePathBatch.StopRecordsTest do
  # Verifies the published form of a route's stops as a pure function of a
  # stored fetch: the record is built from the route path the requester
  # parses out of the live fixture, with a parent station added to it, its
  # CloudEvent is compared whole, and decode/1 is driven with built values
  # altered one rule at a time.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.RoutePathBatch.Records
  alias Gobusgo.OneBusAway.RoutePathBatch.StopRecords
  alias Gobusgo.OneBusAway.RoutePaths

  @fixture_path Path.expand("../../../fixtures/one_bus_away/stops_for_route.json", __DIR__)
  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @destination "raw/oba/stops-for-route/dt=2026-10-05/route=1_100336/file.json.gz"
  @data_sha256 String.duplicate("ab", 32)

  # The fixture's route with its first stop inside a station.
  defp route_path do
    data = @fixture_path |> File.read!() |> JSON.decode!() |> Map.fetch!("data")
    [first, _second] = data["references"]["stops"]
    station = %{first | "id" => "1_station", "name" => "Colman Dock", "routeIds" => []}

    data =
      data
      |> put_in(["references", "stops", Access.at(0), "parent"], "1_station")
      |> update_in(["references", "stops"], &(&1 ++ [station]))

    {:ok, route_path} = RoutePaths.parse(data, "1_100336")
    route_path
  end

  defp parsed(overrides \\ %{}) do
    Map.merge(
      %{
        route_id: "1_100336",
        destination: @destination,
        fetched_at: ~U[2026-10-05 01:59:49Z],
        data_sha256: @data_sha256,
        request_id: @request_id,
        route_path: route_path()
      },
      overrides
    )
  end

  defp alter(value, path, change) do
    value |> JSON.decode!() |> update_in(path, change) |> Gobusgo.CanonicalJson.encode()
  end

  @first_stop %{
    "id" => "1_1889",
    "name" => "Vashon Island Water Taxi & Colman Dock",
    "lat" => 47.601223,
    "lon" => -122.338928,
    "code" => "1889",
    "direction" => nil,
    "locationType" => 0,
    "parent" => "1_station",
    "wheelchairBoarding" => "ACCESSIBLE",
    "routeIds" => ["1_100336", "1_100337"]
  }

  @second_stop %{
    "id" => "1_99997",
    "name" => "Water Taxi Route & Harbor Ave SW",
    "lat" => 47.589374,
    "lon" => -122.37944,
    "code" => "99997",
    "direction" => nil,
    "locationType" => 0,
    "parent" => nil,
    "wheelchairBoarding" => "UNKNOWN",
    "routeIds" => ["1_100336"]
  }

  @parent_stop %{
    "id" => "1_station",
    "name" => "Colman Dock",
    "lat" => 47.601223,
    "lon" => -122.338928,
    "code" => "1889",
    "direction" => nil,
    "locationType" => 0,
    "parent" => nil,
    "wheelchairBoarding" => "ACCESSIBLE",
    "routeIds" => []
  }

  describe "build/1" do
    test "goes to the stop state topic under the route's key" do
      assert Map.take(StopRecords.build(parsed()), [:topic, :key, :headers]) == %{
               topic: "oba.stops.state",
               key: "stops-for-route/1_100336",
               headers: [{"content-type", "application/cloudevents+json"}]
             }
    end

    test "holds the stops of the route and their parent stops as one CloudEvent" do
      assert JSON.decode!(StopRecords.build(parsed()).value) == %{
               "specversion" => "1.0",
               "id" => @request_id <> "/route-stops/1_100336",
               "source" => "/gobusgo/processor/oba/stops-for-route",
               "type" => "gobusgo.route.stops.processed.v1",
               "time" => "2026-10-05T01:59:49Z",
               "subject" => "1_100336",
               "datacontenttype" => "application/json",
               "partitionkey" => "stops-for-route/1_100336",
               "data" => %{
                 "routeId" => "1_100336",
                 "dataSha256" => @data_sha256,
                 "destination" => @destination,
                 "fetchedAt" => "2026-10-05T01:59:49Z",
                 "requestId" => @request_id,
                 "stops" => [@first_stop, @second_stop],
                 "parentStops" => [@parent_stop]
               }
             }
    end

    test "has another event identifier than the route path record of the same fetch" do
      stops_id = JSON.decode!(StopRecords.build(parsed()).value)["id"]
      path_id = JSON.decode!(Records.build(parsed()).value)["id"]

      assert stops_id != path_id
    end

    test "builds the same bytes for the same fetch" do
      assert StopRecords.build(parsed()) == StopRecords.build(parsed())
    end

    for {name, overrides} <- [
          {"a request identifier that is not a UUID version 7", quote(do: %{request_id: "r1"})},
          {"an empty route identifier", quote(do: %{route_id: ""})},
          {"the stops of another route", quote(do: %{route_id: "1_100337"})}
        ] do
      test "raises for #{name}" do
        assert_raise AssertionError, fn -> StopRecords.build(parsed(unquote(overrides))) end
      end
    end
  end

  describe "decode/1" do
    test "returns the fetch a built record holds, the route as its identifier" do
      assert StopRecords.decode(StopRecords.build(parsed()).value) ==
               {:ok,
                %{
                  id: "1_100336",
                  request_id: @request_id,
                  fetched_at: ~U[2026-10-05 01:59:49Z],
                  data_sha256: @data_sha256,
                  destination: @destination,
                  stops: [@first_stop, @second_stop],
                  parent_stops: [@parent_stop]
                }}
    end

    test "leaves out a field this module does not document" do
      value =
        alter(StopRecords.build(parsed()).value, ["data", "stops", Access.at(0)], fn stop ->
          Map.put(stop, "extra", true)
        end)

      assert {:ok, %{stops: [stop, _second]}} = StopRecords.decode(value)
      refute is_map_key(stop, "extra")
    end

    for {name, path, change} <- [
          {"an empty route", quote(do: ["data", "routeId"]), quote(do: fn _ -> "" end)},
          {"a request identifier that is not a UUID version 7", quote(do: ["data", "requestId"]),
           quote(do: fn _ -> "r1" end)},
          {"a fetch time that is not a time", quote(do: ["data", "fetchedAt"]),
           quote(do: fn _ -> "yesterday" end)},
          {"a stop without a name", quote(do: ["data", "stops", Access.at(0)]),
           quote(do: &Map.delete(&1, "name"))},
          {"a stop with an empty identifier", quote(do: ["data", "stops", Access.at(0), "id"]),
           quote(do: fn _ -> "" end)},
          {"a parent stop whose latitude is not a number",
           quote(do: ["data", "parentStops", Access.at(0), "lat"]),
           quote(do: fn _ -> "north" end)},
          {"a stop listed twice", quote(do: ["data", "stops"]),
           quote(do: fn [stop | _] = stops -> [stop | stops] end)},
          {"a parent stop that is also a stop", quote(do: ["data", "parentStops"]),
           quote(do: fn parent_stops -> [@first_stop | parent_stops] end)}
        ] do
      test "rejects #{name}" do
        value = alter(StopRecords.build(parsed()).value, unquote(path), unquote(change))

        assert StopRecords.decode(value) == {:error, :schema_mismatch}
      end
    end

    test "names the record of the route's paths as another type" do
      assert StopRecords.decode(Records.build(parsed()).value) == {:error, :unsupported_type}
      assert Records.decode(StopRecords.build(parsed()).value) == {:error, :unsupported_type}
    end

    test "rejects a value that is not JSON" do
      assert StopRecords.decode("{") == {:error, :invalid_json}
    end
  end
end
