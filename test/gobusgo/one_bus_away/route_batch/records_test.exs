defmodule Gobusgo.OneBusAway.RouteBatch.RecordsTest do
  # Verifies the published form of an agency's routes as a pure function of
  # a stored fetch: the record is built from routes written out here, its
  # CloudEvent is compared whole, and decode/1 is driven with built values
  # altered one rule at a time.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.RouteBatch.Records

  @request_id "0199c4a2-7e1b-7a3f-9d20-000000000001"
  @destination "raw/oba/routes-for-agency/dt=2026-10-05/agency=40/file.json.gz"
  @data_sha256 String.duplicate("ab", 32)

  defp route(overrides) do
    Map.merge(
      %{
        id: "40_100479",
        agency_id: "40",
        short_name: "1 Line",
        long_name: "Lynnwood - Federal Way",
        description: nil,
        type: 0,
        color: "28813F",
        text_color: "FFFFFF",
        url: "https://www.soundtransit.org/1"
      },
      overrides
    )
  end

  defp parsed(overrides \\ %{}) do
    Map.merge(
      %{
        agency_id: "40",
        destination: @destination,
        fetched_at: ~U[2026-10-05 01:17:31Z],
        data_sha256: @data_sha256,
        request_id: @request_id,
        routes: [
          route(%{}),
          route(%{id: "40_100232", short_name: "522", long_name: nil, type: 3})
        ]
      },
      overrides
    )
  end

  defp alter(value, path, change) do
    value |> JSON.decode!() |> update_in(path, change) |> Gobusgo.CanonicalJson.encode()
  end

  describe "build/1" do
    test "goes to the route state topic under the agency's key" do
      assert Map.take(Records.build(parsed()), [:topic, :key, :headers]) == %{
               topic: "oba.routes.state",
               key: "routes-for-agency/40",
               headers: [{"content-type", "application/cloudevents+json"}]
             }
    end

    test "holds the agency's routes in identifier order as one CloudEvent" do
      assert JSON.decode!(Records.build(parsed()).value) == %{
               "specversion" => "1.0",
               "id" => @request_id <> "/routes-for-agency/40",
               "source" => "/gobusgo/processor/oba/routes-for-agency",
               "type" => "gobusgo.agency.routes.processed.v1",
               "time" => "2026-10-05T01:17:31Z",
               "subject" => "40",
               "datacontenttype" => "application/json",
               "partitionkey" => "routes-for-agency/40",
               "data" => %{
                 "agencyId" => "40",
                 "dataSha256" => @data_sha256,
                 "destination" => @destination,
                 "fetchedAt" => "2026-10-05T01:17:31Z",
                 "requestId" => @request_id,
                 "routes" => [
                   %{
                     "id" => "40_100232",
                     "agencyId" => "40",
                     "shortName" => "522",
                     "longName" => nil,
                     "description" => nil,
                     "type" => 3,
                     "color" => "28813F",
                     "textColor" => "FFFFFF",
                     "url" => "https://www.soundtransit.org/1"
                   },
                   %{
                     "id" => "40_100479",
                     "agencyId" => "40",
                     "shortName" => "1 Line",
                     "longName" => "Lynnwood - Federal Way",
                     "description" => nil,
                     "type" => 0,
                     "color" => "28813F",
                     "textColor" => "FFFFFF",
                     "url" => "https://www.soundtransit.org/1"
                   }
                 ]
               }
             }
    end

    test "builds the same bytes for the same fetch" do
      assert Records.build(parsed()) == Records.build(parsed())
    end

    test "builds a record without routes for an agency that has none" do
      assert %{"routes" => []} = JSON.decode!(Records.build(parsed(%{routes: []})).value)["data"]
    end

    for {name, overrides} <- [
          {"a request identifier that is not a UUID version 7", quote(do: %{request_id: "r1"})},
          {"an empty agency identifier", quote(do: %{agency_id: ""})},
          {"a repeated route identifier", quote(do: %{routes: [route(%{}), route(%{})]})}
        ] do
      test "raises for #{name}" do
        assert_raise AssertionError, fn -> Records.build(parsed(unquote(overrides))) end
      end
    end
  end

  describe "decode/1" do
    test "returns the fetch a built record holds, the agency as its identifier" do
      assert {:ok, decoded} = Records.decode(Records.build(parsed()).value)

      assert %{
               id: "40",
               request_id: @request_id,
               fetched_at: ~U[2026-10-05 01:17:31Z],
               data_sha256: @data_sha256,
               destination: @destination,
               route_ids: ["40_100232", "40_100479"]
             } = decoded

      assert decoded.routes["40_100232"] == %{
               "id" => "40_100232",
               "agencyId" => "40",
               "shortName" => "522",
               "longName" => nil,
               "description" => nil,
               "type" => 3,
               "color" => "28813F",
               "textColor" => "FFFFFF",
               "url" => "https://www.soundtransit.org/1"
             }
    end

    test "leaves out a route field this module does not document" do
      value =
        alter(Records.build(parsed()).value, ["data", "routes", Access.at(0)], fn route ->
          Map.put(route, "extra", true)
        end)

      assert {:ok, %{routes: %{"40_100232" => route}}} = Records.decode(value)
      refute is_map_key(route, "extra")
    end

    for {name, path, change} <- [
          {"an empty agency", quote(do: ["data", "agencyId"]), quote(do: fn _ -> "" end)},
          {"a request identifier that is not a UUID version 7", quote(do: ["data", "requestId"]),
           quote(do: fn _ -> "r1" end)},
          {"a fetch time that is not a time", quote(do: ["data", "fetchedAt"]),
           quote(do: fn _ -> "yesterday" end)},
          {"a route without a type", quote(do: ["data", "routes", Access.at(0)]),
           quote(do: &Map.delete(&1, "type"))},
          {"a repeated route", quote(do: ["data", "routes"]),
           quote(do: fn [route | _rest] -> [route, route] end)}
        ] do
      test "rejects #{name}" do
        value = alter(Records.build(parsed()).value, unquote(path), unquote(change))

        assert Records.decode(value) == {:error, :schema_mismatch}
      end
    end

    test "names an event of another type" do
      value = alter(Records.build(parsed()).value, ["type"], fn _ -> "gobusgo.other.v1" end)

      assert Records.decode(value) == {:error, :unsupported_type}
    end

    test "rejects a value that is not JSON" do
      assert Records.decode("{") == {:error, :invalid_json}
    end
  end
end
