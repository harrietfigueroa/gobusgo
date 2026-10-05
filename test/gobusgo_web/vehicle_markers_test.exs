defmodule GobusgoWeb.VehicleMarkersTest do
  # Verifies the markers of one agency's fetch as a pure function over a
  # literal fetch in the form the vehicle view holds, one vehicle per case.
  use ExUnit.Case, async: true

  alias Gobusgo.Assert.AssertionError
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
        "position" => @position,
        "orientation" => nil,
        "lastKnownLocation" => nil,
        "lastKnownOrientation" => nil,
        "lastUpdateTimeMs" => nil,
        "lastLocationUpdateTimeMs" => @fetched_at_ms,
        "predicted" => true
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

  defp marker(fields) do
    assert %{markers: [marker]} = VehicleMarkers.agency_markers(fetch([vehicle(fields)]))
    marker
  end

  describe "agency_markers/1 status" do
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
  end

  describe "agency_markers/1 location age" do
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

  describe "agency_markers/1 real-time availability" do
    for {predicted, text} <- [{true, "Yes"}, {false, "No"}, {nil, "Not supplied"}] do
      test "reads #{inspect(text)} for predicted #{inspect(predicted)}" do
        assert marker(%{"predicted" => unquote(predicted)}).real_time == unquote(text)
      end
    end
  end

  describe "agency_markers/1 heading" do
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
  end

  describe "agency_markers/1" do
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
               VehicleMarkers.agency_markers(fetch(vehicles))
    end

    test "keeps the fetch's vehicle order" do
      vehicles = for id <- ["1_300", "1_100", "1_200"], do: vehicle(%{"id" => id})

      assert %{markers: markers} = VehicleMarkers.agency_markers(fetch(vehicles))
      assert Enum.map(markers, & &1.vehicle_id) == ["1_300", "1_100", "1_200"]
    end

    test "returns no markers and a zero count for a fetch with no vehicles" do
      assert VehicleMarkers.agency_markers(fetch([])) == %{
               agency_id: "1",
               markers: [],
               position_missing_count: 0
             }
    end

    test "raises for a vehicle identifier the fetch holds no vehicle for" do
      fetch = %{fetch([]) | vehicle_ids: ["1_100"]}

      assert_raise AssertionError, fn -> VehicleMarkers.agency_markers(fetch) end
    end
  end

  describe "statuses/0" do
    test "defines every status once, each with a label, a description, and a color" do
      statuses = VehicleMarkers.statuses()

      assert Enum.map(statuses, & &1.status) == [:reported, :stale, :scheduled, :unknown]

      for definition <- statuses do
        assert %{label: label, description: description, color: "#" <> _hex} = definition
        assert label != ""
        assert description != ""
      end
    end

    test "names the stale threshold in the stale status's description" do
      stale = Enum.find(VehicleMarkers.statuses(), &(&1.status == :stale))

      assert stale.description =~ "2 minutes"
    end
  end
end
