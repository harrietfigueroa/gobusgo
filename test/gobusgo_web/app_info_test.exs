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
    test "says what the map shows, as a headline and a caption" do
      assert AppInfo.about() == %{
               headline: "A live transit map of Puget Sound",
               caption: "Where each vehicle is, the routes it runs on, and the stops it serves"
             }
    end
  end

  describe "summary/1" do
    for {topic, headline, caption} <- [
          {:theme, "Theme", "Match system follows your device's light or dark setting"},
          {:offline, "Offline",
           "The map, saved schedules, favorites, and trip planning keep working"},
          {:offline_schedules, "Save schedules offline",
           "Plan trips and see scheduled times without signal"},
          {:show_direction, "Show my direction",
           "Your location dot points the way you face or travel"},
          {:disclaimer, "An independent project",
           "Check with your agency before you rely on a position or a time."},
          {:donation, "Free and independent",
           "Donations pay for its server and storage, and buy no feature or priority"},
          {:location, "Your location stays in your browser",
           "Gobusgo's server never receives it"},
          {:favorite_stop, "Favorites stay in your browser",
           "The server learns a stop only to fetch its arrivals"},
          {:credits, "Data from the region's transit agencies",
           "Served by OneBusAway · map data © OpenStreetMap contributors"}
        ] do
      test "gives #{topic} its headline and caption" do
        assert AppInfo.summary(unquote(topic)) == %{
                 headline: unquote(headline),
                 caption: unquote(caption)
               }
      end
    end
  end

  describe "data_use_facts/1" do
    test "states each cadence in a headline, with its caption" do
      assert AppInfo.data_use_facts(@cadences) == [
               %{
                 headline: "Live vehicles every 5 seconds",
                 caption: "From OneBusAway, while a map is open"
               },
               %{
                 headline: "Arrivals every 30 seconds to 5 minutes",
                 caption: "For the stops you open and your favorites, faster when fewer are open"
               },
               %{
                 headline: "Routes and stops once a day",
                 caption: "Each route at a minute of its own"
               },
               %{
                 headline: "Service alerts with each read",
                 caption: "For the trips running now and the stops that are open"
               }
             ]
    end

    test "states other cadences in the same words as data_use/1" do
      cadences = %{
        vehicle_interval_ms: 10_000,
        route_period_minutes: 360,
        arrival_refresh_age_ms_min: 1_000,
        arrival_refresh_age_ms_max: 60_000
      }

      [vehicle_fact, arrival_fact, route_fact, _alert_fact] = AppInfo.data_use_facts(cadences)

      assert {vehicle_fact.headline, arrival_fact.headline, route_fact.headline} ==
               {"Live vehicles every 10 seconds", "Arrivals every second to a minute",
                "Routes and stops every 6 hours"}
    end

    test "refuses a longest arrival age that is not over the shortest" do
      cadences = %{@cadences | arrival_refresh_age_ms_max: 30_000}

      assert_raise Gobusgo.Assert.AssertionError, fn -> AppInfo.data_use_facts(cadences) end
    end
  end

  describe "shared_vehicles_summary/1" do
    test "states the interval in its headline" do
      assert AppInfo.shared_vehicles_summary(60_000) == %{
               headline: "Scooters and bikes every 60 seconds",
               caption: "Only while a page shows them"
             }
    end
  end

  describe "recorded_summary/1" do
    for {day_count, caption} <- [
          {1, "No address, cookie, or identifier of you, kept a day"},
          {3, "No address, cookie, or identifier of you, kept 3 days"}
        ] do
      test "states a retention of #{day_count} days in its caption" do
        assert AppInfo.recorded_summary(unquote(day_count)) == %{
                 headline: "One anonymous record per page visit",
                 caption: unquote(caption)
               }
      end
    end

    test "refuses a retention of no days" do
      assert_raise Gobusgo.Assert.AssertionError, fn -> AppInfo.recorded_summary(0) end
    end
  end

  describe "license_summary/0" do
    test "names the license in its headline and the copyright line in its caption" do
      assert AppInfo.license_summary() == %{
               headline: "Open source under the MIT License",
               caption: "Copyright (c) 2026 Harriet Waters"
             }
    end
  end

  describe "offline_basemap_summary/1" do
    test "states the size in whole megabytes in its caption" do
      assert AppInfo.offline_basemap_summary(%{bytes: 34_355_445}) == %{
               headline: "Save the map offline",
               caption: "Keeps streets and places when you lose signal · 34 MB"
             }
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
                 "Arrivals are read only for the stop you select on the map and for your " <>
                   "favorite stops, each #{unquote(text)}, less often the more stops are open."
      end
    end

    test "names arrival times among what comes from the source" do
      assert data_use_text(@cadences) =~
               "Vehicle positions, routes, stops, and arrival times come from"
    end

    test "names the source" do
      assert data_use_text(@cadences) =~ "OneBusAway"
    end

    test "says a live vehicle's marker is the map's estimate from its last report" do
      assert data_use_text(@cadences) =~
               "A live vehicle's marker is the map's own estimate: between reports it moves " <>
                 "along its route at the schedule's pace from the last report."
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

  describe "session_cookie/1" do
    @fourteen_days_seconds 1_209_600
    @one_day_seconds 86_400

    test "says the cookie lasts the days it is given" do
      assert AppInfo.session_cookie(@fourteen_days_seconds) =~ "for 14 days"
    end

    test "says the cookie holds only the token that protects the forms" do
      assert AppInfo.session_cookie(@fourteen_days_seconds) =~
               "holds only the security token that protects the page's forms"
    end

    test "says the server records nothing about the cookie" do
      assert AppInfo.session_cookie(@fourteen_days_seconds) =~ "records nothing about it"
    end

    test "states the endpoint's cookie lifetime" do
      day_count = div(GobusgoWeb.Endpoint.session_cookie_age_seconds(), @one_day_seconds)

      assert AppInfo.session_cookie(GobusgoWeb.Endpoint.session_cookie_age_seconds()) =~
               "for #{day_count} days"
    end

    test "refuses an age that is not whole days" do
      assert_raise Gobusgo.Assert.AssertionError, fn ->
        AppInfo.session_cookie(@one_day_seconds + 1)
      end
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

  describe "offline_basemap/1" do
    for {bytes, size} <- [
          {34_355_445, "about 34 MB"},
          {33_500_000, "about 34 MB"},
          {1_499_999, "about 1 MB"}
        ] do
      test "states the size of #{bytes} bytes as #{size}" do
        assert AppInfo.offline_basemap(%{bytes: unquote(bytes)}) =~ unquote(size)
      end
    end

    test "says the saved map has less detail close in" do
      assert AppInfo.offline_basemap(%{bytes: 1}) =~ "with less detail close in"
    end

    test "says the saving waits for the page to load and turning it off removes the copy" do
      text = AppInfo.offline_basemap(%{bytes: 1})

      assert text =~ "after the page has loaded"
      assert text =~ "turning this off removes it"
    end
  end

  describe "offline/0" do
    test "says the map draws its background offline only from a saved map" do
      %{works: works} = AppInfo.offline()

      assert Enum.any?(works, &(&1 =~ "With Save the map offline on"))
    end

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
                 &(AppInfo.needs_connection(&1).headline <> ".")
               )
    end
  end

  describe "needs_connection/1" do
    test "names each part of the page that needs a connection, in the decided terms" do
      back_online = "They come back when you're online."

      messages = %{
        arrivals: %{headline: "Live arrivals need a connection", caption: back_online},
        alerts: %{headline: "Service alerts need a connection", caption: back_online},
        suggestions: %{headline: "Suggestions need a connection", caption: back_online},
        shared_vehicles: %{headline: "Scooters and bikes need a connection", caption: back_online}
      }

      for {part, message} <- messages do
        assert AppInfo.needs_connection(part) == message
      end
    end

    test "says the same of live arrivals as the arrivals' texts in the browser" do
      source = File.read!("assets/js/stop_arrivals.js")
      %{headline: headline, caption: caption} = AppInfo.needs_connection(:arrivals)

      assert source =~
               ~s[const ARRIVALS_NEED_CONNECTION = Object.freeze({headline: "#{headline}", caption: "#{caption}"})]
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

  describe "address_sources/0" do
    test "credits King, Pierce, and Snohomish counties, each with the layer used" do
      assert [
               %{operator: "King County", layer: "Addresses in King County"},
               %{operator: "Pierce County", layer: "Address_Points"},
               %{operator: "Snohomish County", layer: "Building Address Points"}
             ] = AppInfo.address_sources()
    end

    test "links each county's terms at an https address" do
      assert [
               %{terms: %{name: "King County GIS Center terms and conditions", url: king_url}},
               %{terms: %{name: "Pierce County GIS Data Terms of Use", url: pierce_url}},
               %{terms: %{name: "Building Address Points item license", url: snohomish_url}}
             ] = AppInfo.address_sources()

      assert king_url ==
               "https://kingcounty.gov/en/dept/kcit/data-information-services/gis-center/about/terms-conditions-copyrights"

      assert pierce_url ==
               "https://matterhorn.piercecountywa.gov/Disclaimer/PierceCountyGISDataTermsofUse.pdf"

      assert snohomish_url ==
               "https://www.arcgis.com/home/item.html?id=3c07edee19f142d2926dc1f7e4efc474"
    end

    test "gives each source an id of its own and a summary that says it is provided as is" do
      sources = AppInfo.address_sources()

      assert sources |> Enum.map(& &1.id) |> Enum.uniq() |> length() == 3

      for %{summary: summary} <- sources do
        assert summary =~ "as is" or summary =~ "no warranty"
      end
    end

    test "passes on each section of Pierce County's terms that disclaims, under the terms' headings" do
      %{disclaimers: disclaimers} = Enum.find(AppInfo.address_sources(), &(&1.id == "pierce"))

      assert Enum.map(disclaimers, & &1.title) == [
               "Data warranty disclaimer",
               "Liability disclaimer",
               "No authority to act as County",
               "Termination of data availability"
             ]
    end

    # Each disclaimer is quoted from the terms of 29 May 2026, so each case
    # pins the first and the last sentence it quotes as the terms word them.
    for {title, first, last} <- [
          {"Data warranty disclaimer",
           ~s(All Pierce County GIS data is expressly provided “AS IS” and “WITH ALL FAULTS”.),
           "makes no warranty concerning same."},
          {"Liability disclaimer",
           "Pierce County disclaims any responsibility or legal liability to users",
           "inaccurate, incomplete or otherwise defective in any way."},
          {"No authority to act as County",
           "Users are not authorized by Pierce County to combine this Data with other data",
           "a user has no authority to represent its products or services as though user " <>
             "were a County agent or office."},
          {"Termination of data availability",
           "Pierce County reserves the right to modify the Data in any way",
           "the violation of any provision of these Terms of Use."}
        ] do
      test "quotes Pierce County's #{title} from its first sentence to its last" do
        %{disclaimers: disclaimers} =
          Enum.find(AppInfo.address_sources(), &(&1.id == "pierce"))

        %{text: text} = Enum.find(disclaimers, &(&1.title == unquote(title)))
        assert String.starts_with?(text, unquote(first))
        assert String.ends_with?(text, unquote(last))
      end
    end

    test "tells the rider what Pierce County's terms require a user be told" do
      %{summary: summary} = Enum.find(AppInfo.address_sources(), &(&1.id == "pierce"))

      assert summary =~
               "Pierce County does not warrant the Data in any way and makes each of the " <>
                 "disclaimers set forth in its terms of use"
    end

    test "carries Snohomish County's license text as its disclaimer" do
      %{disclaimers: [%{text: text}]} =
        Enum.find(AppInfo.address_sources(), &(&1.id == "snohomish"))

      assert text =~ "makes no representation or warranty concerning the content"
      assert text =~ "hold Snohomish County harmless"
      assert text =~ "Ch. 42.56 RCW"
      assert text =~ "no commercial use may be made of any Data comprising lists of individuals"
    end

    test "King County states no disclaimer to pass on" do
      assert %{disclaimers: []} = Enum.find(AppInfo.address_sources(), &(&1.id == "king"))
    end

    test "no credit mentions a logo or says the application is a product of a county" do
      for source <- AppInfo.address_sources() do
        refute inspect(source) =~ "logo"
        refute inspect(source) =~ "direct product"
      end
    end
  end

  describe "intersection_source/0" do
    test "credits OpenStreetMap and links the ODbL at an https address" do
      assert %{
               credit: "OpenStreetMap contributors",
               license: %{
                 name: "Open Database License 1.0",
                 url: "https://opendatacommons.org/licenses/odbl/1-0/"
               },
               path: "/intersections/",
               summary: summary
             } = AppInfo.intersection_source()

      assert summary =~ "derivative database"
      assert summary =~ "same license"
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

  describe "places_license/0" do
    test "states the places file's license and its credit" do
      assert %{name: "Places", license: "ODbL 1.0, © OpenStreetMap contributors"} =
               AppInfo.places_license()
    end

    test "links the ODbL, the copyright page, and the manifest of the places file" do
      assert AppInfo.places_license().links == [
               %{
                 text: "Open Database License 1.0",
                 url: "https://opendatacommons.org/licenses/odbl/1-0/"
               },
               %{text: "OpenStreetMap copyright", url: "https://www.openstreetmap.org/copyright"},
               %{text: "Places file", url: "/places/manifest.json"}
             ]
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
