defmodule Gobusgo.OneBusAway.RoutePathBatch.RecordsTest do
  # Verifies the published form of a route's paths as a pure function of a
  # stored fetch: the record is built from the route path the requester
  # parses out of the live fixture, its CloudEvent is compared whole, and
  # decode/1 is driven with built values altered one rule at a time.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.RouteBatch
  alias Gobusgo.OneBusAway.RoutePathBatch.Records
  alias Gobusgo.OneBusAway.RoutePaths

  @fixture_path Path.expand("../../../fixtures/one_bus_away/stops_for_route.json", __DIR__)
  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @destination "raw/oba/stops-for-route/dt=2026-10-05/route=1_100336/file.json.gz"
  @data_sha256 String.duplicate("ab", 32)

  defp route_path do
    data = @fixture_path |> File.read!() |> JSON.decode!() |> Map.fetch!("data")
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

  @route_polyline %{"points" => "mbpaHphuiVJVbhAn|F", "pointCount" => 3, "levels" => nil}

  describe "build/1" do
    test "goes to the route state topic under the route's key" do
      assert Map.take(Records.build(parsed()), [:topic, :key, :headers]) == %{
               topic: "oba.routes.state",
               key: "stops-for-route/1_100336",
               headers: [{"content-type", "application/cloudevents+json"}]
             }
    end

    test "holds the lines of the route and of each stop group as one CloudEvent" do
      assert JSON.decode!(Records.build(parsed()).value) == %{
               "specversion" => "1.0",
               "id" => @request_id <> "/stops-for-route/1_100336",
               "source" => "/gobusgo/processor/oba/stops-for-route",
               "type" => "gobusgo.route.path.processed.v1",
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
                 "polylines" => [@route_polyline],
                 "stopGroupings" => [
                   %{
                     "type" => "direction",
                     "ordered" => true,
                     "stopGroups" => [
                       %{
                         "id" => "1",
                         "name" => "Downtown Seattle Water Taxi",
                         "names" => ["Downtown Seattle Water Taxi"],
                         "nameType" => "destination",
                         "stopIds" => ["1_99997", "1_1889"],
                         "polylines" => [
                           %{"points" => "}xmaHxf}iVchAo|FKW", "pointCount" => 3, "levels" => nil}
                         ]
                       },
                       %{
                         "id" => "0",
                         "name" => "West Seattle Water Taxi",
                         "names" => ["West Seattle Water Taxi"],
                         "nameType" => "destination",
                         "stopIds" => ["1_1889", "1_99997"],
                         "polylines" => [@route_polyline]
                       }
                     ]
                   }
                 ]
               }
             }
    end

    test "leaves the referenced stops out" do
      refute Records.build(parsed()).value =~ "Colman Dock"
    end

    test "builds the same bytes for the same fetch" do
      assert Records.build(parsed()) == Records.build(parsed())
    end

    for {name, overrides} <- [
          {"a request identifier that is not a UUID version 7", quote(do: %{request_id: "r1"})},
          {"an empty route identifier", quote(do: %{route_id: ""})},
          {"the path of another route", quote(do: %{route_id: "1_100337"})}
        ] do
      test "raises for #{name}" do
        assert_raise AssertionError, fn -> Records.build(parsed(unquote(overrides))) end
      end
    end
  end

  describe "decode/1" do
    test "returns the fetch a built record holds, the route as its identifier" do
      assert {:ok, decoded} = Records.decode(Records.build(parsed()).value)

      assert %{
               id: "1_100336",
               request_id: @request_id,
               fetched_at: ~U[2026-10-05 01:59:49Z],
               data_sha256: @data_sha256,
               destination: @destination,
               polylines: [@route_polyline],
               stop_groupings: [%{"type" => "direction", "stopGroups" => [first, _second]}]
             } = decoded

      assert first["stopIds"] == ["1_99997", "1_1889"]
    end

    test "leaves out a field this module does not document" do
      value =
        alter(Records.build(parsed()).value, ["data", "polylines", Access.at(0)], fn polyline ->
          Map.put(polyline, "extra", true)
        end)

      assert {:ok, %{polylines: [polyline]}} = Records.decode(value)
      refute is_map_key(polyline, "extra")
    end

    for {name, path, change} <- [
          {"an empty route", quote(do: ["data", "routeId"]), quote(do: fn _ -> "" end)},
          {"a request identifier that is not a UUID version 7", quote(do: ["data", "requestId"]),
           quote(do: fn _ -> "r1" end)},
          {"a fetch time that is not a time", quote(do: ["data", "fetchedAt"]),
           quote(do: fn _ -> "yesterday" end)},
          {"a polyline without points", quote(do: ["data", "polylines", Access.at(0)]),
           quote(do: &Map.delete(&1, "points"))}
        ] do
      test "rejects #{name}" do
        value = alter(Records.build(parsed()).value, unquote(path), unquote(change))

        assert Records.decode(value) == {:error, :schema_mismatch}
      end
    end

    test "names the record of an agency's routes as another type" do
      routes =
        RouteBatch.Records.build(%{
          agency_id: "1",
          destination: "raw/oba/routes-for-agency/dt=2026-10-05/agency=1/file.json.gz",
          fetched_at: ~U[2026-10-05 01:59:49Z],
          data_sha256: @data_sha256,
          request_id: @request_id,
          routes: []
        })

      assert Records.decode(routes.value) == {:error, :unsupported_type}

      assert RouteBatch.Records.decode(Records.build(parsed()).value) ==
               {:error, :unsupported_type}
    end

    test "rejects a value that is not JSON" do
      assert Records.decode("{") == {:error, :invalid_json}
    end
  end
end
