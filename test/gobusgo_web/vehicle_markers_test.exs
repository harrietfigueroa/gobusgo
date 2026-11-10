defmodule GobusgoWeb.VehicleMarkersTest do
  # Verifies the markers of one agency's fetch as a pure function over a
  # literal fetch in the form the vehicle view holds, one vehicle per case.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
  alias Gobusgo.OneBusAway.VehicleBatch.Records
  alias Gobusgo.OneBusAway.Vehicles
  alias GobusgoWeb.RouteLines
  alias GobusgoWeb.VehicleMarkers

  @fetched_at ~U[2026-10-02 03:15:00Z]
  @fetched_at_ms DateTime.to_unix(@fetched_at, :millisecond)
  @position %{"lat" => 47.66, "lon" => -122.34}

  defp vehicle(fields) do
    Map.merge(
      %{
        "id" => "1_100",
        "agencyId" => "1",
        "activeTripId" => nil,
        "routeId" => nil,
        "routeShortName" => nil,
        "routeLongName" => nil,
        "tripHeadsign" => nil,
        "position" => @position,
        "orientation" => nil,
        "lastKnownLocation" => nil,
        "lastKnownOrientation" => nil,
        "lastUpdateTimeMs" => nil,
        "lastLocationUpdateTimeMs" => @fetched_at_ms,
        "predicted" => true,
        "scheduleDeviationSeconds" => nil,
        "nextStopId" => nil,
        "nextStopTimeOffsetSeconds" => nil,
        "serviceDateMs" => nil
      },
      fields
    )
  end

  defp fetch(vehicles) do
    %{
      agency_id: "1",
      request_id: "0199c4a2-7e1b-7a3f-9d20-000000000001",
      fetched_at: @fetched_at,
      vehicle_ids: Enum.map(vehicles, & &1["id"]),
      vehicles: Map.new(vehicles, &{&1["id"], &1})
    }
  end

  @route_colors %{"1_100479" => "#e11d48"}
  @no_lookups %{stop_names: %{}, route_colors: %{}}

  defp marker(fields, stop_names \\ %{}) do
    lookups = %{stop_names: stop_names, route_colors: @route_colors}
    assert %{markers: [marker]} = VehicleMarkers.agency_markers(fetch([vehicle(fields)]), lookups)

    marker
  end

  describe "agency_markers/2 status" do
    for {name, age_ms, status} <- [
          {"reported at the fetch time", 0, :reported},
          {"reported at the stale threshold", 120_000, :reported},
          {"reported one millisecond past the stale threshold", 120_001, :stale},
          {"reported after the fetch time", -5_000, :reported}
        ] do
      test "is #{status} for a location #{name}" do
        report_time_ms = @fetched_at_ms - unquote(age_ms)

        assert marker(%{"lastLocationUpdateTimeMs" => report_time_ms}).status ==
                 unquote(status)
      end
    end

    test "is scheduled for a vehicle that has never reported a location" do
      assert marker(%{"lastLocationUpdateTimeMs" => 0}).status == :scheduled
    end

    test "is unknown for a vehicle with no report time supplied" do
      assert marker(%{"lastLocationUpdateTimeMs" => nil}).status == :unknown
    end

    test "is scheduled for a vehicle without real-time data, however recent its report" do
      assert marker(%{"predicted" => false}).status == :scheduled
    end

    test "is judged by the report for a vehicle whose real-time availability is not supplied" do
      assert marker(%{"predicted" => nil}).status == :reported
    end
  end

  describe "agency_markers/2 location age" do
    for {age_ms, text} <- [
          {0, "0 s ago"},
          {59_999, "59 s ago"},
          {65_000, "1 min 5 s ago"},
          {3_725_000, "1 h 2 min ago"},
          {-5_000, "0 s ago"}
        ] do
      test "reads #{inspect(text)} for a report #{age_ms} ms before the fetch" do
        report_time_ms = @fetched_at_ms - unquote(age_ms)

        assert marker(%{"lastLocationUpdateTimeMs" => report_time_ms}).location_age ==
                 unquote(text)
      end
    end

    test "says that no location was reported for a vehicle that has never reported" do
      assert marker(%{"lastLocationUpdateTimeMs" => 0}).location_age == "No location reported"
    end

    test "says that the report time was not supplied" do
      assert marker(%{"lastLocationUpdateTimeMs" => nil}).location_age == "Not supplied"
    end
  end

  describe "agency_markers/2 real-time availability" do
    for {predicted, text} <- [{true, "Yes"}, {false, "No"}, {nil, "Not supplied"}] do
      test "reads #{inspect(text)} for predicted #{inspect(predicted)}" do
        assert marker(%{"predicted" => unquote(predicted)}).real_time == unquote(text)
      end
    end
  end

  describe "agency_markers/2 heading" do
    for {name, orientation, heading} <- [
          {"east", 0, 90},
          {"north", 90, 0},
          {"west", 180, 270},
          {"south", 270, 180},
          {"north-east as a fraction", 45.0, 45},
          {"a fraction of a degree short of east", 359.6, 90},
          {"a fraction of a degree west of north", 90.4, 0},
          {"an angle of a full turn or more", 450, 0},
          {"an angle below zero", -90, 180}
        ] do
      test "is #{heading} degrees clockwise from north for an orientation of #{name}" do
        assert marker(%{"orientation" => unquote(orientation)}).heading == unquote(heading)
      end
    end

    test "is absent for a vehicle with no orientation supplied" do
      assert marker(%{"orientation" => nil}).heading == nil
    end

    test "comes from the orientation of the estimated position, never the last reported one" do
      assert marker(%{"orientation" => 180, "lastKnownOrientation" => 90}).heading == 270
    end

    for {name, fields} <- [
          {"without real-time data", %{"predicted" => false}},
          {"that has never reported a location", %{"lastLocationUpdateTimeMs" => 0}}
        ] do
      test "is absent for a vehicle #{name}, whose orientation comes from the schedule" do
        fields = Map.put(unquote(Macro.escape(fields)), "orientation", 90)

        assert marker(fields).heading == nil
      end
    end
  end

  describe "agency_markers/2 color" do
    for {name, fields} <- [
          {"reported recently", %{}},
          {"whose last report is stale",
           %{"lastLocationUpdateTimeMs" => @fetched_at_ms - 600_000}},
          {"with no report time supplied", %{"lastLocationUpdateTimeMs" => nil}}
        ] do
      test "is the route's color for a vehicle #{name}" do
        fields = Map.put(unquote(Macro.escape(fields)), "routeId", "1_100479")

        assert marker(fields).color == "#e11d48"
      end
    end

    test "is the color of a route with none for a route the colors do not hold" do
      assert marker(%{"routeId" => "1_404"}).color == RouteLines.default_color()
    end

    test "is the color of a route with none for a vehicle with no route" do
      assert marker(%{"routeId" => nil}).color == RouteLines.default_color()
    end

    for {name, fields} <- [
          {"without real-time data", %{"predicted" => false}},
          {"that has never reported a location", %{"lastLocationUpdateTimeMs" => 0}}
        ] do
      test "is the schedule-only color for a vehicle #{name}, whatever its route" do
        fields = Map.put(unquote(Macro.escape(fields)), "routeId", "1_100479")
        scheduled = Enum.find(VehicleMarkers.statuses(), &(&1.status == :scheduled))

        assert marker(fields).color == scheduled.color
      end
    end
  end

  describe "agency_markers/2 route" do
    for {name, short_name, long_name, route} <- [
          {"the short name of a route that has both names", "44", "Ballard - Montlake", "44"},
          {"the long name of a route with no short name", nil, "Seattle - Bainbridge Island",
           "Seattle - Bainbridge Island"},
          {"absent for a route with no name", nil, nil, nil}
        ] do
      test "is #{name}" do
        fields = %{
          "routeShortName" => unquote(short_name),
          "routeLongName" => unquote(long_name)
        }

        assert marker(fields).route == unquote(route)
      end
    end

    test "comes with the trip's headsign" do
      assert marker(%{"tripHeadsign" => "University District"}).headsign == "University District"
    end

    test "comes with no headsign for a trip that has none" do
      assert marker(%{"tripHeadsign" => nil}).headsign == nil
    end
  end

  describe "agency_markers/2 schedule" do
    for {deviation_seconds, text} <- [
          {180, "3 min late"},
          {239, "3 min late"},
          {60, "1 min late"},
          {-60, "1 min early"},
          {-95, "1 min early"},
          {2_130, "35 min late"},
          {59, "on time"},
          {0, "on time"},
          {-59, "on time"}
        ] do
      test "reads #{inspect(text)} for a deviation of #{deviation_seconds} seconds" do
        assert marker(%{"scheduleDeviationSeconds" => unquote(deviation_seconds)}).schedule ==
                 unquote(text)
      end
    end

    test "is absent for a vehicle with no deviation supplied" do
      assert marker(%{"scheduleDeviationSeconds" => nil}).schedule == nil
    end

    test "is absent for a vehicle that has never reported a location" do
      fields = %{"scheduleDeviationSeconds" => 180, "lastLocationUpdateTimeMs" => 0}

      assert marker(fields).schedule == nil
    end

    for {name, report_time_ms} <- [
          {"whose last report is stale", @fetched_at_ms - 600_000},
          {"with no report time supplied", nil}
        ] do
      test "is absent for a vehicle #{name}" do
        fields = %{
          "scheduleDeviationSeconds" => 180,
          "lastLocationUpdateTimeMs" => unquote(report_time_ms)
        }

        assert marker(fields).schedule == nil
      end
    end
  end

  describe "agency_markers/2 next stop" do
    @stop_names %{"1_29247" => "Pine St & 3rd Ave"}

    for {offset_seconds, text} <- [
          {140, "Pine St & 3rd Ave, 2 min away"},
          {60, "Pine St & 3rd Ave, 1 min away"},
          {59, "Pine St & 3rd Ave, under 1 min away"},
          {0, "Pine St & 3rd Ave, under 1 min away"},
          {3_597, "Pine St & 3rd Ave, 59 min away"}
        ] do
      test "reads #{inspect(text)} for a stop #{offset_seconds} seconds away" do
        fields = %{
          "nextStopId" => "1_29247",
          "nextStopTimeOffsetSeconds" => unquote(offset_seconds)
        }

        assert marker(fields, @stop_names).next_stop == unquote(text)
      end
    end

    test "is the time alone for a stop that has no name" do
      fields = %{"nextStopId" => "1_404", "nextStopTimeOffsetSeconds" => 140}

      assert marker(fields, @stop_names).next_stop == "2 min away"
    end

    test "is the name alone for a stop with no offset supplied" do
      fields = %{"nextStopId" => "1_29247", "nextStopTimeOffsetSeconds" => nil}

      assert marker(fields, @stop_names).next_stop == "Pine St & 3rd Ave"
    end

    test "is the name alone for an offset before zero" do
      fields = %{"nextStopId" => "1_29247", "nextStopTimeOffsetSeconds" => -30}

      assert marker(fields, @stop_names).next_stop == "Pine St & 3rd Ave"
    end

    test "is absent for a vehicle with no next stop supplied" do
      assert marker(%{}, @stop_names).next_stop == nil
    end

    test "is kept for a vehicle that has never reported a location" do
      fields = %{
        "nextStopId" => "1_29247",
        "nextStopTimeOffsetSeconds" => 140,
        "lastLocationUpdateTimeMs" => 0
      }

      assert marker(fields, @stop_names).next_stop == "Pine St & 3rd Ave, 2 min away"
    end

    for {name, report_time_ms} <- [
          {"whose last report is stale", @fetched_at_ms - 600_000},
          {"with no report time supplied", nil}
        ] do
      test "is absent for a vehicle #{name}" do
        fields = %{
          "nextStopId" => "1_29247",
          "nextStopTimeOffsetSeconds" => 140,
          "lastLocationUpdateTimeMs" => unquote(report_time_ms)
        }

        assert marker(fields, @stop_names).next_stop == nil
      end
    end
  end

  describe "next_stop_ids/1" do
    test "names each next stop of the fetch's vehicles once, sorted" do
      vehicles = [
        vehicle(%{"id" => "1_a", "nextStopId" => "1_700"}),
        vehicle(%{"id" => "1_b", "nextStopId" => "1_200"}),
        vehicle(%{"id" => "1_c", "nextStopId" => "1_700"}),
        vehicle(%{"id" => "1_d", "nextStopId" => nil})
      ]

      assert VehicleMarkers.next_stop_ids(fetch(vehicles)) == ["1_200", "1_700"]
    end

    test "names no stop for a fetch with no vehicles" do
      assert VehicleMarkers.next_stop_ids(fetch([])) == []
    end
  end

  describe "route_name/1" do
    test "is the short name before the long name" do
      vehicle = vehicle(%{"routeShortName" => "44", "routeLongName" => "Ballard - Montlake"})

      assert VehicleMarkers.route_name(vehicle) == "44"
    end

    test "is absent for a vehicle with no route" do
      assert VehicleMarkers.route_name(vehicle(%{})) == nil
    end
  end

  describe "agency_markers/2" do
    test "places a marker at the estimated position, never the last reported location" do
      marker = marker(%{"lastKnownLocation" => %{"lat" => 47.0, "lon" => -122.0}})

      assert %{id: "1/1_100", vehicle_id: "1_100", lat: 47.66, lon: -122.34} = marker
    end

    test "counts a vehicle with no position and gives it no marker" do
      vehicles = [
        vehicle(%{"id" => "1_100"}),
        vehicle(%{"id" => "1_200", "position" => nil}),
        vehicle(%{"id" => "1_300", "position" => nil})
      ]

      assert %{agency_id: "1", markers: [%{vehicle_id: "1_100"}], position_missing_count: 2} =
               VehicleMarkers.agency_markers(fetch(vehicles), @no_lookups)
    end

    test "keeps the fetch's vehicle order" do
      vehicles = for id <- ["1_300", "1_100", "1_200"], do: vehicle(%{"id" => id})

      assert %{markers: markers} = VehicleMarkers.agency_markers(fetch(vehicles), @no_lookups)
      assert Enum.map(markers, & &1.vehicle_id) == ["1_300", "1_100", "1_200"]
    end

    test "returns no markers and a zero count for a fetch with no vehicles" do
      assert VehicleMarkers.agency_markers(fetch([]), @no_lookups) == %{
               agency_id: "1",
               fetched_at_ms: @fetched_at_ms,
               markers: [],
               position_missing_count: 0
             }
    end

    test "raises for a vehicle identifier the fetch holds no vehicle for" do
      fetch = %{fetch([]) | vehicle_ids: ["1_100"]}

      assert_raise AssertionError, fn -> VehicleMarkers.agency_markers(fetch, @no_lookups) end
    end

    test "carries the fetch time in milliseconds since the Unix epoch" do
      vehicles = [vehicle(%{"id" => "1_100"})]

      assert %{fetched_at_ms: @fetched_at_ms} =
               VehicleMarkers.agency_markers(fetch(vehicles), @no_lookups)
    end
  end

  describe "agency_markers/2 last report" do
    @report_location %{"lat" => 47.65, "lon" => -122.33}

    test "is the last reported location and its time" do
      report_time_ms = @fetched_at_ms - 64_000

      fields = %{
        "lastKnownLocation" => @report_location,
        "lastLocationUpdateTimeMs" => report_time_ms
      }

      assert marker(fields).report == %{lat: 47.65, lon: -122.33, time_ms: report_time_ms}
    end

    test "is kept for a stale vehicle" do
      fields = %{
        "lastKnownLocation" => @report_location,
        "lastLocationUpdateTimeMs" => @fetched_at_ms - 600_000
      }

      assert %{status: :stale, report: %{lat: 47.65, lon: -122.33}} = marker(fields)
    end

    for {name, fields} <- [
          {"with no location supplied", %{"lastKnownLocation" => nil}},
          {"that has never reported a location",
           %{"lastKnownLocation" => @report_location, "lastLocationUpdateTimeMs" => 0}},
          {"with no report time supplied",
           %{"lastKnownLocation" => @report_location, "lastLocationUpdateTimeMs" => nil}}
        ] do
      test "is absent for a vehicle #{name}" do
        assert marker(unquote(Macro.escape(fields))).report == nil
      end
    end
  end

  describe "agency_markers/2 trip" do
    test "is the trip the vehicle serves and the start of its service date" do
      fields = %{"activeTripId" => "1_15436438", "serviceDateMs" => 1_790_924_400_000}

      assert %{trip_id: "1_15436438", service_date_ms: 1_790_924_400_000} = marker(fields)
    end

    test "is absent for a vehicle that serves no trip" do
      assert %{trip_id: nil, service_date_ms: nil} = marker(%{})
    end
  end

  describe "agency_markers/2 over a stored fetch" do
    # The fixture is cut from a stored `vehicles-for-agency` response of
    # agency 40. It goes through the requester's parse, the published
    # records, and their decoding, as the vehicle view receives it.
    @fixture_path Path.expand("../fixtures/one_bus_away/vehicles_for_agency.json", __DIR__)
    @stored_fetched_at DateTime.from_unix!(1_790_985_910)

    defp stored_markers do
      data = @fixture_path |> File.read!() |> JSON.decode!() |> Map.fetch!("data")
      {:ok, parsed} = Vehicles.parse(data)

      %{vehicles: records} =
        Records.build(%{
          agency_id: "40",
          destination: "raw/oba/vehicles-for-agency/agency=40/file.json",
          fetched_at: @stored_fetched_at,
          data_sha256: String.duplicate("ab", 32),
          request_id: "0199c4a2-7e1b-7a3f-9d20-5b6c1e8f4a10",
          vehicles: parsed
        })

      vehicles =
        for record <- records do
          {:ok, {:vehicle, %{vehicle: vehicle}}} = Records.decode(record.value)
          vehicle
        end

      fetch = %{fetch(vehicles) | agency_id: "40", fetched_at: @stored_fetched_at}
      %{markers: markers} = VehicleMarkers.agency_markers(fetch, @no_lookups)
      Map.new(markers, &{&1.vehicle_id, &1})
    end

    test "gives a reported vehicle its last report, trip, and service date" do
      assert %{
               report: %{
                 lat: 47.3177375793457,
                 lon: -122.2967300415039,
                 time_ms: 1_790_985_895_000
               },
               trip_id: "40_1655020",
               service_date_ms: 1_790_924_400_000
             } = Map.fetch!(stored_markers(), "40_41605")
    end

    test "gives a vehicle that has never reported a location no report" do
      vehicle_id = "40_H:121:0:Weekday:1:26SEP:52043:12345"

      assert %{report: nil, trip_id: "40_16687274__H:121:0:Weekday:1:26SEP:52043:12345"} =
               Map.fetch!(stored_markers(), vehicle_id)
    end
  end

  describe "glyph_zoom_min/0" do
    test "draws a bus glyph from zoom 13" do
      assert VehicleMarkers.glyph_zoom_min() == 13
    end
  end

  describe "statuses/0" do
    test "defines every status once, each with a label, a description, and an opacity" do
      statuses = VehicleMarkers.statuses()

      assert Enum.map(statuses, & &1.status) == [:reported, :stale, :scheduled, :unknown]

      for definition <- statuses do
        assert %{label: label, description: description, opacity: opacity} = definition
        assert label != ""
        assert description != ""
        assert opacity > 0
        assert opacity <= 1
      end
    end

    test "gives the schedule-only status a color of its own and the others their route's" do
      colors = Map.new(VehicleMarkers.statuses(), &{&1.status, &1.color})

      assert %{reported: nil, stale: nil, unknown: nil, scheduled: "#" <> _hex} = colors
    end

    test "draws a stale or unknown marker fainter than a recent one" do
      opacities = Map.new(VehicleMarkers.statuses(), &{&1.status, &1.opacity})

      assert opacities.stale < opacities.reported
      assert opacities.unknown < opacities.reported
    end

    test "gives each status a recent report lacks a badge of its own, and a recent one none" do
      badges = Map.new(VehicleMarkers.statuses(), &{&1.status, &1.badge})

      assert badges == %{reported: nil, stale: :clock, unknown: :question, scheduled: :timetable}
    end

    test "names its badge in the description of each status that has one" do
      for %{badge: badge, description: description} <- VehicleMarkers.statuses(), badge != nil do
        assert description =~ VehicleMarkers.badge_name(badge)
      end
    end

    test "names the stale threshold in the stale status's description" do
      stale = Enum.find(VehicleMarkers.statuses(), &(&1.status == :stale))

      assert stale.description =~ "2 minutes"
    end
  end
end
