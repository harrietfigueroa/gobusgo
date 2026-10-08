defmodule GobusgoWeb.StopArrivalsTest do
  # Verifies what a page shows of a stop's arrivals as a pure function over
  # a literal fetch in the form the arrivals view holds, literal vehicles in
  # the form the vehicle view holds, and a time, one arrival per case.
  use ExUnit.Case, async: true

  alias GobusgoWeb.StopArrivals

  @now ~U[2026-10-07 02:30:00Z]
  @now_ms DateTime.to_unix(@now, :millisecond)

  defp in_minutes(minutes), do: @now_ms + minutes * 60_000

  defp arrival(fields) do
    Map.merge(
      %{
        "tripId" => "1_800582101",
        "serviceDateMs" => 1_791_270_000_000,
        "stopSequence" => 5,
        "routeId" => "1_100210",
        "routeShortName" => "36",
        "routeLongName" => "Othello Station - Downtown Seattle",
        "tripHeadsign" => "Othello Station",
        "arrivalEnabled" => true,
        "departureEnabled" => true,
        "scheduledArrivalTimeMs" => in_minutes(10),
        "scheduledDepartureTimeMs" => in_minutes(10),
        "predicted" => true,
        "predictedArrivalTimeMs" => in_minutes(12),
        "predictedDepartureTimeMs" => in_minutes(12),
        "vehicleId" => "1_4342",
        "vehicleScheduleDeviationSeconds" => 120
      },
      fields
    )
  end

  defp fetch(arrivals, fetched_at \\ @now) do
    %{
      id: "1_1471",
      request_id: "0199c4a2-7e1b-7a3f-9d20-000000000001",
      fetched_at: fetched_at,
      data_sha256: String.duplicate("ab", 32),
      destination: "raw/oba/arrivals-and-departures-for-stop/file.json.gz",
      arrivals: arrivals
    }
  end

  defp vehicle(fields) do
    Map.merge(
      %{"id" => "1_4342", "activeTripId" => "1_800582101", "scheduleDeviationSeconds" => 120},
      fields
    )
  end

  defp shown(arrivals, vehicles \\ %{}) do
    StopArrivals.arrivals(%{fetch: fetch(arrivals), vehicles: vehicles, now: @now})
  end

  defp line(fields, vehicles \\ %{}) do
    assert %{arrivals: [line]} = shown([arrival(fields)], vehicles)
    line
  end

  describe "waiting/1" do
    test "names the stop and that its arrivals are awaited" do
      assert StopArrivals.waiting("1_1471") == %{stop_id: "1_1471", status: :waiting}
    end
  end

  describe "arrivals/1" do
    test "names the stop and holds the arrival's route, headsign, minutes, and kind" do
      assert shown([arrival(%{})]) == %{
               stop_id: "1_1471",
               status: :arrivals,
               age_minutes: 0,
               arrivals: [
                 %{route: "36", headsign: "Othello Station", minutes: 12, predicted: true}
               ]
             }
    end

    test "holds no arrival for a fetch without arrivals" do
      assert %{status: :arrivals, arrivals: []} = shown([])
    end

    for {name, age_seconds, age_minutes} <- [
          {"just made", 0, 0},
          {"made 59 seconds ago", 59, 0},
          {"made four and a half minutes ago", 270, 4},
          {"made after the time it is", -30, 0}
        ] do
      test "gives the age of a fetch #{name} as #{age_minutes} minutes" do
        fetched_at = DateTime.add(@now, -unquote(age_seconds), :second)

        assert %{age_minutes: unquote(age_minutes)} =
                 StopArrivals.arrivals(%{fetch: fetch([], fetched_at), vehicles: %{}, now: @now})
      end
    end
  end

  describe "arrivals/1 time" do
    test "is the prediction where the fetch holds one" do
      assert %{minutes: 12, predicted: true} = line(%{})
    end

    test "is the schedule, marked as such, where the fetch holds no prediction" do
      fields = %{"predicted" => false, "predictedArrivalTimeMs" => nil}

      assert %{minutes: 10, predicted: false} = line(fields)
    end

    test "is in whole minutes, the part of a minute left out" do
      fields = %{"predictedArrivalTimeMs" => in_minutes(3) - 1}

      assert line(fields).minutes == 2
    end

    test "is zero minutes for an arrival within the minute" do
      assert line(%{"predictedArrivalTimeMs" => @now_ms}).minutes == 0
    end

    test "is the departure where riders cannot arrive on the trip" do
      fields = %{
        "arrivalEnabled" => false,
        "predictedArrivalTimeMs" => nil,
        "scheduledDepartureTimeMs" => in_minutes(20),
        "predictedDepartureTimeMs" => in_minutes(21)
      }

      assert %{minutes: 21, predicted: true} = line(fields)
    end

    test "is the scheduled departure where the departure has no prediction" do
      fields = %{
        "arrivalEnabled" => false,
        "scheduledDepartureTimeMs" => in_minutes(20),
        "predictedDepartureTimeMs" => nil
      }

      assert %{minutes: 20, predicted: false} = line(fields)
    end
  end

  describe "arrivals/1 deviation" do
    test "moves an arrival two minutes later for a vehicle two minutes later than at the fetch" do
      vehicles = %{"1_4342" => vehicle(%{"scheduleDeviationSeconds" => 240})}

      assert line(%{}, vehicles).minutes == 14
    end

    test "moves an arrival earlier for a vehicle that made up time" do
      vehicles = %{"1_4342" => vehicle(%{"scheduleDeviationSeconds" => 0})}

      assert line(%{}, vehicles).minutes == 10
    end

    test "keeps the time for a vehicle as late as it was at the fetch" do
      assert line(%{}, %{"1_4342" => vehicle(%{})}).minutes == 12
    end

    for {name, vehicles} <- [
          {"the vehicle view does not hold", quote(do: %{})},
          {"that serves another trip now",
           quote(
             do: %{
               "1_4342" => %{
                 "id" => "1_4342",
                 "activeTripId" => "1_9",
                 "scheduleDeviationSeconds" => 600
               }
             }
           )},
          {"whose deviation is not supplied now",
           quote(
             do: %{
               "1_4342" => %{
                 "id" => "1_4342",
                 "activeTripId" => "1_800582101",
                 "scheduleDeviationSeconds" => nil
               }
             }
           )}
        ] do
      test "keeps the time for a vehicle #{name}" do
        assert line(%{}, unquote(vehicles)).minutes == 12
      end
    end

    test "keeps the time for an arrival whose vehicle was on another trip at the fetch" do
      vehicles = %{"1_4342" => vehicle(%{"scheduleDeviationSeconds" => 600})}

      assert line(%{"vehicleScheduleDeviationSeconds" => nil}, vehicles).minutes == 12
    end

    test "keeps the schedule of an arrival with no prediction, whatever its vehicle" do
      vehicles = %{"1_4342" => vehicle(%{"scheduleDeviationSeconds" => 600})}
      fields = %{"predicted" => false, "predictedArrivalTimeMs" => nil}

      assert %{minutes: 10, predicted: false} = line(fields, vehicles)
    end
  end

  describe "arrivals/1 selection" do
    test "leaves out an arrival whose time has passed" do
      assert %{arrivals: []} = shown([arrival(%{"predictedArrivalTimeMs" => @now_ms - 1})])
    end

    test "leaves out an arrival that a vehicle's lost delay puts in the past" do
      vehicles = %{"1_4342" => vehicle(%{"scheduleDeviationSeconds" => 0})}
      fields = %{"predictedArrivalTimeMs" => in_minutes(1)}

      assert %{arrivals: []} = shown([arrival(fields)], vehicles)
    end

    test "puts the soonest arrival first" do
      arrivals = [
        arrival(%{"tripId" => "1_a", "predictedArrivalTimeMs" => in_minutes(9)}),
        arrival(%{"tripId" => "1_b", "predictedArrivalTimeMs" => in_minutes(3)}),
        arrival(%{"tripId" => "1_c", "predictedArrivalTimeMs" => in_minutes(6)})
      ]

      assert Enum.map(shown(arrivals).arrivals, & &1.minutes) == [3, 6, 9]
    end

    test "shows the sooner of a trip the source lists twice" do
      arrivals = [
        arrival(%{"vehicleId" => "1_4342", "predictedArrivalTimeMs" => in_minutes(9)}),
        arrival(%{"vehicleId" => "1_8274297", "predictedArrivalTimeMs" => in_minutes(7)})
      ]

      assert Enum.map(shown(arrivals).arrivals, & &1.minutes) == [7]
    end

    test "shows at most eight arrivals" do
      arrivals =
        for index <- 1..9 do
          arrival(%{"tripId" => "1_#{index}", "predictedArrivalTimeMs" => in_minutes(index)})
        end

      assert StopArrivals.arrival_count_max() == 8
      assert Enum.map(shown(arrivals).arrivals, & &1.minutes) == Enum.to_list(1..8)
    end
  end

  describe "arrivals/1 route" do
    test "is the long name of a route that has no short name" do
      assert line(%{"routeShortName" => nil}).route == "Othello Station - Downtown Seattle"
    end

    test "is absent for a route with neither name, and so is a headsign not supplied" do
      fields = %{"routeShortName" => nil, "routeLongName" => nil, "tripHeadsign" => nil}

      assert %{route: nil, headsign: nil} = line(fields)
    end
  end

  describe "arrivals/1 headsign" do
    for {name, short_name, headsign, expected} <- [
          {"loses the route's short name it starts with", "578", "578 Puyallup", "Puyallup"},
          {"is kept when it does not start with the short name", "36", "Othello Station",
           "Othello Station"},
          {"is kept when the short name is the start of a longer word", "5", "56th Street",
           "56th Street"},
          {"is kept when it is the short name alone", "578", "578", "578"},
          {"is kept when it names the short name later", "578", "Puyallup 578", "Puyallup 578"}
        ] do
      test name do
        fields = %{"routeShortName" => unquote(short_name), "tripHeadsign" => unquote(headsign)}

        assert line(fields).headsign == unquote(expected)
      end
    end

    test "is kept for a route shown by its long name" do
      fields = %{
        "routeShortName" => nil,
        "routeLongName" => "Seattle",
        "tripHeadsign" => "Seattle Bainbridge Island"
      }

      assert line(fields).headsign == "Seattle Bainbridge Island"
    end
  end

  describe "vehicle_ids/1" do
    test "names each vehicle whose deviation can move an arrival, once, sorted" do
      arrivals = [
        arrival(%{"vehicleId" => "1_b"}),
        arrival(%{"vehicleId" => "1_a"}),
        arrival(%{"vehicleId" => "1_b", "tripId" => "1_2"}),
        arrival(%{"vehicleId" => "1_c", "vehicleScheduleDeviationSeconds" => nil}),
        arrival(%{"vehicleId" => nil, "vehicleScheduleDeviationSeconds" => nil})
      ]

      assert StopArrivals.vehicle_ids(fetch(arrivals)) == ["1_a", "1_b"]
    end

    test "names no vehicle for a fetch without arrivals" do
      assert StopArrivals.vehicle_ids(fetch([])) == []
    end
  end
end
