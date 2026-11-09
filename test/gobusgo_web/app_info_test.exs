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
                 "While a stop's popup or its view in the panel is open, the arrivals at that stop are read " <>
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
               "the agencies' alerts for the trips running now and for the stops that are open"
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

    test "says the button keeps the map on the rider until the rider moves it" do
      assert AppInfo.location() =~
               "keeps the map on you as you move, until you move the map yourself"
    end

    test "says what the browser remembers" do
      assert AppInfo.location() =~ "remembers only whether you left the button on"
    end

    test "says the dot points the way the rider faces or travels, and that the direction stays in the browser" do
      assert AppInfo.location() =~
               "With Show my direction on, the dot also points the way you face or travel, " <>
                 "from your device's compass or your movement. That never leaves your browser either."
    end

    test "states the whole text of the location button" do
      assert AppInfo.location() ==
               "The location button shows where you are on the map and keeps the map on you " <>
                 "as you move, until you move the map yourself. Your browser asks you first, " <>
                 "and your position never leaves your browser: Gobusgo's server does not " <>
                 "receive it. The browser remembers only whether you left the button on, so " <>
                 "the map follows you again on your next visit. With Show my direction on, " <>
                 "the dot also points the way you face or travel, from your device's compass " <>
                 "or your movement. That never leaves your browser either."
    end
  end

  describe "show_direction/0" do
    test "says what the setting draws" do
      assert AppInfo.show_direction() =~
               "the dot of your location points the way you face or travel"
    end

    test "says when Safari on an iPhone asks for motion access" do
      assert AppInfo.show_direction() =~
               "Safari on an iPhone asks for access to motion the first time"
    end
  end

  describe "donation/0" do
    test "says Gobusgo is free and independent" do
      assert AppInfo.donation() =~ "Gobusgo is free to use and independent"
    end

    test "says donations go toward its running costs" do
      assert AppInfo.donation() =~ "Donations go toward the cost of running it"
    end

    test "says a donation buys no feature, data, or priority" do
      assert AppInfo.donation() =~ "A donation buys no feature, no data, and no priority"
    end

    test "names no agency" do
      refute AppInfo.donation() =~ "agenc"
      refute AppInfo.donation() =~ "Transit"
      refute AppInfo.donation() =~ "Metro"
    end
  end

  describe "donation_label/0" do
    test "is Support gobusgo on Ko-fi" do
      assert AppInfo.donation_label() == "Support gobusgo on Ko-fi"
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

  describe "offline_schedules/0" do
    test "says the browser saves the region's schedules for today and tomorrow" do
      assert AppInfo.offline_schedules() =~
               "saves the schedules of the region for today and tomorrow"
    end

    test "says the saving waits for the page to load" do
      assert AppInfo.offline_schedules() =~ "after the page has loaded"
    end

    test "says turning the setting off removes them" do
      assert AppInfo.offline_schedules() =~ "turning this off removes them"
    end
  end

  describe "offline/0" do
    test "says the vehicles and the arrivals come from the saved schedules" do
      %{works: works} = AppInfo.offline()

      assert Enum.any?(works, &(&1 =~ "where the saved schedules place them"))
      assert Enum.any?(works, &(&1 =~ "delays, cancellations, and detours unknown"))
      assert Enum.any?(works, &(&1 =~ "arrivals are its scheduled times"))
    end

    test "says the browser keeps the favorites, the filter, and the settings" do
      %{works: works} = AppInfo.offline()

      assert Enum.any?(works, &(&1 =~ "favorite stops, your filter, and your settings"))
    end

    test "says trip planning and centering on a favorite work from the saved schedules" do
      %{works: works} = AppInfo.offline()

      assert Enum.any?(works, &(&1 =~ "plan a trip and center the map on a favorite stop"))
    end

    test "lists each thing that needs a connection by the text it says in place" do
      %{needs_connection: needs_connection} = AppInfo.offline()

      assert needs_connection ==
               Enum.map(
                 [:arrivals, :alerts, :suggestions, :shared_vehicles],
                 &(AppInfo.needs_connection(&1) <> ".")
               )
    end
  end

  describe "needs_connection/1" do
    test "names each part of the page that needs a connection, in the decided terms" do
      texts = %{
        arrivals: "Live arrivals need a connection",
        alerts: "Service alerts need a connection",
        suggestions: "Suggestions need a connection",
        shared_vehicles: "Scooters and bikes need a connection"
      }

      for {part, text} <- texts do
        assert AppInfo.needs_connection(part) == text
      end
    end

    test "says the same of live arrivals as the arrivals' texts in the browser" do
      source = File.read!("assets/js/stop_arrivals.js")

      assert source =~
               ~s(const ARRIVALS_NEED_CONNECTION = "#{AppInfo.needs_connection(:arrivals)}")
    end
  end

  describe "theme/0" do
    test "says the browser remembers the theme" do
      assert AppInfo.theme() =~ "Your browser remembers the theme you choose"
    end

    test "says Match system follows the device's setting while the page is open" do
      assert AppInfo.theme() =~
               "Match system follows the light or dark setting of your device while the page is open"
    end

    test "says the server never learns it" do
      assert AppInfo.theme() =~ "Gobusgo's server never learns it"
    end
  end

  describe "shared_vehicles/1" do
    @shared_vehicle_facts %{
      operators: ["Lime"],
      vehicle_file_names: ["vehicle_status", "free_bike_status", "free_bike_status"],
      interval_ms: 60_000,
      types_period_minutes: 1_440,
      stored_age_ms_max: 600_000
    }

    defp shared_vehicles_text(facts \\ %{}) do
      @shared_vehicle_facts |> Map.merge(facts) |> AppInfo.shared_vehicles() |> Enum.join(" ")
    end

    test "names each vehicle file once" do
      assert shared_vehicles_text() =~ "vehicle_status or free_bike_status,"
    end

    test "says the vehicle types are requested once a day" do
      assert shared_vehicles_text() =~ "vehicle types once a day"
    end

    test "says a request carries no key and no data about the rider" do
      assert shared_vehicles_text() =~ "no key and no data about you"
    end

    for {interval_ms, text} <- [{60_000, "every 60 seconds"}, {300_000, "every 300 seconds"}] do
      test "says the vehicles are requested #{text} for an interval of #{interval_ms} ms" do
        assert shared_vehicles_text(%{interval_ms: unquote(interval_ms)}) =~
                 "#{unquote(text)} for every page that shows it together"
      end
    end

    test "says nothing is requested while no page shows the layer" do
      assert shared_vehicles_text() =~ "never while no page shows it"
    end

    test "says what a page shows" do
      assert shared_vehicles_text() =~ "position, its form factor, and its remaining range"
    end

    for {age_ms, text} <- [{600_000, "at most 10 minutes"}, {300_000, "at most 5 minutes"}] do
      test "says responses are kept #{text} for an age of #{age_ms} ms" do
        assert shared_vehicles_text(%{stored_age_ms_max: unquote(age_ms)}) =~ unquote(text)
      end
    end

    test "says nothing kept is keyed on a vehicle's identifier" do
      assert shared_vehicles_text() =~ "Nothing it keeps is keyed on a vehicle's identifier"
    end

    test "says the browser downloads tiles from gobusgo and never the operator's feed" do
      assert shared_vehicles_text() =~ "from Gobusgo, never Lime's feed"
    end

    test "refuses a kept age that is no whole count of minutes" do
      assert_raise Gobusgo.Assert.AssertionError, fn ->
        shared_vehicles_text(%{stored_age_ms_max: 90_000})
      end
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
