defmodule Gobusgo.OneBusAway.ArrivalBatch.RecordsTest do
  # Verifies the published form of one fetch of a stop's arrivals as a pure
  # function of its input: the expected key and event are written out by
  # hand and compared with the decoded record, for an arrival that supplies
  # every field and for one that supplies only what the source always sends.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.ArrivalBatch.Records
  alias Gobusgo.OneBusAway.RoutePathBatch

  @request_id "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10"
  @destination "raw/oba/arrivals-and-departures-for-stop/dt=2026-10-07/stop=1_1471/file.json.gz"
  @data_sha256 String.duplicate("ab", 32)

  defp predicted_arrival do
    %{
      trip_id: "1_800582101",
      service_date_ms: 1_791_270_000_000,
      stop_sequence: 5,
      route_id: "1_100210",
      route_short_name: "36",
      route_long_name: "Othello Station - Downtown Seattle",
      trip_headsign: "Othello Station N Beacon Hill",
      arrival_enabled: true,
      departure_enabled: true,
      scheduled_arrival_time_ms: 1_791_336_600_000,
      scheduled_departure_time_ms: 1_791_336_600_000,
      predicted: true,
      predicted_arrival_time_ms: 1_791_336_729_000,
      predicted_departure_time_ms: 1_791_336_729_000,
      vehicle_id: "1_4342",
      vehicle_schedule_deviation_seconds: 129
    }
  end

  defp scheduled_arrival do
    %{
      predicted_arrival()
      | trip_id: "1_800582102",
        route_short_name: nil,
        route_long_name: nil,
        trip_headsign: nil,
        predicted: false,
        predicted_arrival_time_ms: nil,
        predicted_departure_time_ms: nil,
        vehicle_id: nil,
        vehicle_schedule_deviation_seconds: nil
    }
  end

  defp parsed(arrivals, overrides \\ %{}) do
    Map.merge(
      %{
        stop_id: "1_1471",
        destination: @destination,
        fetched_at: ~U[2026-10-07 02:17:05Z],
        data_sha256: @data_sha256,
        request_id: @request_id,
        arrivals: arrivals
      },
      overrides
    )
  end

  defp rewritten(record, change) do
    record.value |> JSON.decode!() |> change.() |> JSON.encode!()
  end

  describe "build/1" do
    test "goes to the arrivals state topic under the stop's key" do
      record = Records.build(parsed([predicted_arrival()]))

      assert Map.take(record, [:topic, :key, :headers]) == %{
               topic: "oba.arrivals.state",
               key: "arrivals/1_1471",
               headers: [{"content-type", "application/cloudevents+json"}]
             }
    end

    test "holds every arrival of the fetch as one CloudEvent" do
      record = Records.build(parsed([predicted_arrival()]))

      assert JSON.decode!(record.value) == %{
               "specversion" => "1.0",
               "id" => "#{@request_id}/arrivals/1_1471",
               "source" => "/gobusgo/processor/oba/arrivals-and-departures-for-stop",
               "type" => "gobusgo.stop.arrivals.processed.v1",
               "time" => "2026-10-07T02:17:05Z",
               "subject" => "1_1471",
               "datacontenttype" => "application/json",
               "partitionkey" => "arrivals/1_1471",
               "data" => %{
                 "stopId" => "1_1471",
                 "arrivals" => [
                   %{
                     "tripId" => "1_800582101",
                     "serviceDateMs" => 1_791_270_000_000,
                     "stopSequence" => 5,
                     "routeId" => "1_100210",
                     "routeShortName" => "36",
                     "routeLongName" => "Othello Station - Downtown Seattle",
                     "tripHeadsign" => "Othello Station N Beacon Hill",
                     "arrivalEnabled" => true,
                     "departureEnabled" => true,
                     "scheduledArrivalTimeMs" => 1_791_336_600_000,
                     "scheduledDepartureTimeMs" => 1_791_336_600_000,
                     "predicted" => true,
                     "predictedArrivalTimeMs" => 1_791_336_729_000,
                     "predictedDepartureTimeMs" => 1_791_336_729_000,
                     "vehicleId" => "1_4342",
                     "vehicleScheduleDeviationSeconds" => 129
                   }
                 ],
                 "dataSha256" => @data_sha256,
                 "destination" => @destination,
                 "fetchedAt" => "2026-10-07T02:17:05Z",
                 "requestId" => @request_id
               }
             }
    end

    test "carries a field the source did not supply as null" do
      record = Records.build(parsed([scheduled_arrival()]))
      [arrival] = JSON.decode!(record.value)["data"]["arrivals"]

      assert Map.take(arrival, [
               "routeShortName",
               "routeLongName",
               "tripHeadsign",
               "predictedArrivalTimeMs",
               "predictedDepartureTimeMs",
               "vehicleId",
               "vehicleScheduleDeviationSeconds"
             ]) == %{
               "routeShortName" => nil,
               "routeLongName" => nil,
               "tripHeadsign" => nil,
               "predictedArrivalTimeMs" => nil,
               "predictedDepartureTimeMs" => nil,
               "vehicleId" => nil,
               "vehicleScheduleDeviationSeconds" => nil
             }
    end

    test "keeps the arrivals in the order given, a trip listed twice included" do
      second = %{predicted_arrival() | vehicle_id: "1_8274297"}
      record = Records.build(parsed([predicted_arrival(), second, scheduled_arrival()]))
      arrivals = JSON.decode!(record.value)["data"]["arrivals"]

      assert Enum.map(arrivals, &{&1["tripId"], &1["vehicleId"]}) == [
               {"1_800582101", "1_4342"},
               {"1_800582101", "1_8274297"},
               {"1_800582102", nil}
             ]
    end

    test "holds no arrival for a fetch without arrivals" do
      record = Records.build(parsed([]))

      assert JSON.decode!(record.value)["data"]["arrivals"] == []
    end

    test "builds the same bytes for the same fetch" do
      assert Records.build(parsed([predicted_arrival()])) ==
               Records.build(parsed([predicted_arrival()]))
    end

    for {name, overrides} <- [
          {"a request identifier that is not a UUID version 7", %{request_id: "request"}},
          {"an empty stop identifier", %{stop_id: ""}}
        ] do
      test "raises for #{name}" do
        assert_raise AssertionError, fn ->
          Records.build(parsed([predicted_arrival()], unquote(Macro.escape(overrides))))
        end
      end
    end

    test "raises for an arrival whose predicted time is not an integer" do
      arrival = %{predicted_arrival() | predicted_arrival_time_ms: 1.5}

      assert_raise AssertionError, fn -> Records.build(parsed([arrival])) end
    end
  end

  describe "decode/1" do
    test "returns the fetch a built record holds, the stop as its identifier" do
      record = Records.build(parsed([predicted_arrival(), scheduled_arrival()]))

      assert {:ok,
              %{
                id: "1_1471",
                request_id: @request_id,
                fetched_at: ~U[2026-10-07 02:17:05Z],
                data_sha256: @data_sha256,
                destination: @destination,
                arrivals: [
                  %{"tripId" => "1_800582101", "predictedArrivalTimeMs" => 1_791_336_729_000},
                  %{"tripId" => "1_800582102", "predictedArrivalTimeMs" => nil}
                ]
              }} = Records.decode(record.value)
    end

    test "leaves out a field this module does not document" do
      record = Records.build(parsed([predicted_arrival()]))

      value =
        rewritten(record, fn event ->
          update_in(event, ["data", "arrivals"], fn [arrival] ->
            [Map.put(arrival, "occupancyStatus", "FULL")]
          end)
        end)

      assert {:ok, %{arrivals: [arrival]}} = Records.decode(value)
      refute is_map_key(arrival, "occupancyStatus")
      assert arrival["tripId"] == "1_800582101"
    end

    for {name, change} <- [
          {"a value that is not a CloudEvent", quote(do: &Map.delete(&1, "specversion"))},
          {"an empty stop identifier", quote(do: &put_in(&1, ["data", "stopId"], ""))},
          {"arrivals that are not a list", quote(do: &put_in(&1, ["data", "arrivals"], %{}))},
          {"an arrival without its trip",
           quote(do: &put_in(&1, ["data", "arrivals"], [%{"routeId" => "1_100210"}]))},
          {"a fetch time that is not a time",
           quote(do: &put_in(&1, ["data", "fetchedAt"], "yesterday"))},
          {"a request identifier that is not a UUID version 7",
           quote(do: &put_in(&1, ["data", "requestId"], "request"))}
        ] do
      test "rejects #{name}" do
        record = Records.build(parsed([predicted_arrival()]))

        assert Records.decode(rewritten(record, unquote(change))) == {:error, :schema_mismatch}
      end
    end

    test "names the record of another dataset as another type" do
      record = Records.build(parsed([predicted_arrival()]))
      value = rewritten(record, &Map.put(&1, "type", "gobusgo.route.path.processed.v1"))

      assert Records.decode(value) == {:error, :unsupported_type}
      assert {:error, _reason} = RoutePathBatch.Records.decode(record.value)
    end

    test "rejects a value that is not JSON" do
      assert Records.decode("{") == {:error, :invalid_json}
    end
  end
end
