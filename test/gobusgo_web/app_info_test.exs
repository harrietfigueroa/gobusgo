defmodule GobusgoWeb.AppInfoTest do
  # Verifies the texts of the info panel as pure functions of the cadences
  # they are given, and checks the license entries against the two files
  # that own those facts: the lock file of the vendored packages and the
  # repository's license.
  use ExUnit.Case, async: true

  alias GobusgoWeb.AppInfo

  @lock_path "assets/vendor.lock.json"
  @license_path "LICENSE"
  @cadences %{
    vehicle_interval_ms: 5_000,
    route_period_minutes: 1_440,
    arrival_refresh_age_ms_min: 30_000,
    arrival_refresh_age_ms_max: 300_000
  }

  defp data_use_text(cadences), do: cadences |> AppInfo.data_use() |> Enum.join(" ")

  describe "about/0" do
    test "says what the map shows" do
      assert AppInfo.about() =~ "Puget Sound"
    end
  end

  describe "data_use/1" do
    for {vehicle_interval_ms, text} <- [
          {1_000, "every second"},
          {5_000, "every 5 seconds"},
          {60_000, "every 60 seconds"}
        ] do
      test "says vehicles are read #{text} for an interval of #{vehicle_interval_ms} ms" do
        cadences = %{@cadences | vehicle_interval_ms: unquote(vehicle_interval_ms)}

        assert data_use_text(cadences) =~ "read #{unquote(text)}"
      end
    end

    for {route_period_minutes, text} <- [
          {60, "every hour"},
          {720, "every 12 hours"},
          {1_440, "once a day"}
        ] do
      test "says routes and stops are read #{text} for a period of #{route_period_minutes} minutes" do
        cadences = %{@cadences | route_period_minutes: unquote(route_period_minutes)}

        assert data_use_text(cadences) =~ "read #{unquote(text)}"
      end
    end

    for {age_ms_min, age_ms_max, text} <- [
          {30_000, 300_000, "every 30 seconds to 5 minutes"},
          {1_000, 60_000, "every second to a minute"},
          {60_000, 90_000, "every minute to 90 seconds"}
        ] do
      test "says a stop's arrivals are read #{text} for ages of #{age_ms_min} to #{age_ms_max} ms" do
        cadences = %{
          @cadences
          | arrival_refresh_age_ms_min: unquote(age_ms_min),
            arrival_refresh_age_ms_max: unquote(age_ms_max)
        }

        assert data_use_text(cadences) =~
                 "While a stop's popup is open, the arrivals at that stop are read " <>
                   "#{unquote(text)}, less often the more stops are open."
      end
    end

    test "names arrival times among what comes from the source" do
      assert data_use_text(@cadences) =~
               "Vehicle positions, routes, stops, and arrival times come from"
    end

    test "names the source" do
      assert data_use_text(@cadences) =~ "OneBusAway"
    end

    test "says the alerts are those of the trips running and of the open stops" do
      assert data_use_text(@cadences) =~
               "the agencies' alerts for the trips running now and for the stops whose popups are open"
    end

    for {label, fields} <- [
          {"a vehicle interval that is no whole count of seconds", %{vehicle_interval_ms: 1_500}},
          {"a vehicle interval of zero", %{vehicle_interval_ms: 0}},
          {"a route period that is no whole count of hours", %{route_period_minutes: 90}},
          {"a route period of zero", %{route_period_minutes: 0}},
          {"an arrival refresh age that is no whole count of seconds",
           %{arrival_refresh_age_ms_min: 1_500}},
          {"an arrival refresh age of zero", %{arrival_refresh_age_ms_min: 0}},
          {"a longest arrival refresh age that is not over the shortest",
           %{arrival_refresh_age_ms_max: 30_000}}
        ] do
      test "refuses #{label}" do
        cadences = Map.merge(@cadences, unquote(Macro.escape(fields)))

        assert_raise Gobusgo.Assert.AssertionError, fn -> AppInfo.data_use(cadences) end
      end
    end
  end

  describe "disclaimer/0" do
    test "says the app is independent and that no agency endorses it" do
      disclaimer = AppInfo.disclaimer()

      assert disclaimer =~ "independent project"
      assert disclaimer =~ "not endorsed by"
      assert disclaimer =~ "transit agencies"
    end
  end

  describe "recorded/0" do
    test "has one entry for every field of a usage record, and for nothing else" do
      fields = for %{field: field} <- AppInfo.recorded(), do: field

      assert Enum.sort(fields) == Gobusgo.Usage.Records.fields()
    end

    test "says something of every field" do
      for %{text: text} <- AppInfo.recorded() do
        assert String.ends_with?(text, ".")
      end
    end
  end

  describe "recorded_retention/1" do
    for {day_count, text} <- [
          {1, "kept for a day"},
          {3, "kept for 3 days"},
          {30, "kept for 30 days"}
        ] do
      test "says a record is #{text} for a retention of #{day_count} days" do
        assert AppInfo.recorded_retention(unquote(day_count)) =~ unquote(text)
      end
    end

    test "refuses a retention of no days" do
      assert_raise Gobusgo.Assert.AssertionError, fn -> AppInfo.recorded_retention(0) end
    end
  end

  describe "recorded_never/0" do
    test "says a record holds no address and no identifier" do
      assert AppInfo.recorded_never() =~ "no IP address"
      assert AppInfo.recorded_never() =~ "no identifier"
    end
  end

  describe "location/0" do
    test "says the rider's position stays in the browser" do
      assert AppInfo.location() =~ "never leaves your browser"
    end

    test "says the browser asks before it gives a position" do
      assert AppInfo.location() =~ "asks you first"
    end

    test "says what the browser remembers" do
      assert AppInfo.location() =~ "remembers only that you used the button"
    end
  end

  describe "favorite_stop/0" do
    test "says the browser remembers the favorite stops" do
      assert AppInfo.favorite_stop() =~ "Your browser remembers your favorite stops"
    end

    test "says the server learns each stop only to fetch its arrivals" do
      assert AppInfo.favorite_stop() =~ "each stop only to fetch its arrivals"
    end

    test "says no usage record holds the stops" do
      assert AppInfo.favorite_stop() =~ "no usage record holds them"
    end
  end

  describe "terms/0" do
    test "names the terms the data is provided under, at an https address" do
      assert %{name: "Transit Data Terms of Use", url: "https://www.soundtransit.org/" <> _path} =
               AppInfo.terms()
    end
  end

  describe "app_license/0" do
    test "states the license and the copyright line of the repository's license" do
      %{name: name, copyright: copyright} = AppInfo.app_license()
      [first_line | rest] = @license_path |> File.read!() |> String.split("\n")

      assert first_line == name
      assert copyright in rest
    end
  end

  describe "components/0" do
    test "names a license for every vendored package and archive" do
      lock = @lock_path |> File.read!() |> JSON.decode!()
      locked_names = for entry <- lock["packages"] ++ lock["archives"], do: entry["name"]

      named = Enum.flat_map(AppInfo.components(), & &1.lock_names)

      assert Enum.sort(named) == Enum.sort(locked_names)
    end

    test "gives every component a name and a license" do
      for component <- AppInfo.components() do
        assert %{name: <<_, _::binary>>, license: <<_, _::binary>>} = component
      end
    end
  end
end
