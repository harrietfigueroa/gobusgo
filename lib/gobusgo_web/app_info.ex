defmodule GobusgoWeb.AppInfo do
  @ms_per_second 1_000
  @ms_per_minute 60_000
  @minutes_per_hour 60
  @hours_per_day 24

  @moduledoc """
  What the info panel of a map page says about the application: what it is,
  that it is independent of the agencies, how it uses OneBusAway data,
  how it uses the rider's location,
  how it keeps favorite stops,
  how it keeps the theme,
  what works offline and what needs a connection,
  how it uses shared scooter and bike data,
  what donations fund,
  what it records of a page connection, the terms that data is provided under, and
  the licenses of the application and of what a page ships to the browser.
  Everything here is pure, so the cadences a text states are the ones it is
  given and a test reads every text.

  `data_use/1` states a vehicle interval in whole seconds and a route period
  in whole hours, a period of #{@hours_per_day} hours as once a day. It
  states each arrival refresh age in whole minutes where it is a whole count
  of them, and in whole seconds otherwise.
  """

  alias Gobusgo.Assert

  @type cadences :: %{
          vehicle_interval_ms: pos_integer(),
          route_period_minutes: pos_integer(),
          arrival_refresh_age_ms_min: pos_integer(),
          arrival_refresh_age_ms_max: pos_integer()
        }

  @type terms :: %{name: String.t(), url: String.t()}

  @type recorded_field :: %{field: String.t(), text: String.t()}

  @type app_license :: %{name: String.t(), copyright: String.t()}

  @typedoc """
  One thing a page ships to the browser, with its license. `lock_names` are
  the entries of the vendored packages' lock file the component stands for,
  none for a component that is no vendored package.
  """
  @type component :: %{name: String.t(), license: String.t(), lock_names: [String.t()]}

  @about "Gobusgo is a live map of public transit in the Puget Sound region: " <>
           "where each vehicle is, the routes it runs on, and the stops it serves."

  @disclaimer "Gobusgo is an independent project. It is not endorsed by, affiliated with, " <>
                "or run by any of the transit agencies whose data it shows, Sound Transit, " <>
                "or the OneBusAway project. Check with your agency before you rely on a " <>
                "position or a time."

  # Section 4 has the terms given to everyone who receives the data, and
  # section 7 allows naming the agencies as providing it "as is".
  # https://www.soundtransit.org/help-contacts/business-information/open-transit-data-otd/transit-data-terms-use — checked 2026-10-08
  @terms %{
    name: "Transit Data Terms of Use",
    url:
      "https://www.soundtransit.org/help-contacts/business-information/open-transit-data-otd/transit-data-terms-use"
  }

  @recorded [
    %{field: "connectedAt", text: "When the page connected."},
    %{field: "durationMs", text: "How long the page stayed connected."},
    %{field: "page", text: "Which page it was."},
    %{field: "reconnect", text: "Whether it was a page already open that connected again."},
    %{field: "filter", text: "The agencies and routes of the filter the page showed last."},
    %{
      field: "filterValueOmittedCount",
      text: "How many values of a long filter were left out of the record."
    },
    %{
      field: "deviceClass",
      text: "Whether the device is a phone, a tablet, a desktop computer, or a crawler."
    },
    %{field: "browserFamily", text: "The family of the browser, such as Firefox or Safari."},
    %{field: "viewportWidthBucket", text: "Which of five ranges the window's width falls in."},
    %{field: "language", text: "The browser's language, without the region."},
    %{field: "referrerHost", text: "The site that linked here, without the page on it."}
  ]

  @recorded_never "A record holds no IP address, no cookie, no identifier of you or your " <>
                    "device, and not the text your browser identifies itself with. Records " <>
                    "of different visits cannot be told to be from the same visitor."

  # The data terms forbid an agency's name or mark in the name of an
  # application or business, so the donation texts name Gobusgo alone.
  # https://www.soundtransit.org/help-contacts/business-information/open-transit-data-otd/transit-data-terms-use — checked 2026-10-06
  @donation "Gobusgo is free to use and independent. Donations go toward the cost of " <>
              "running it: its server and the storage of the data it reads. A donation " <>
              "buys no feature, no data, and no priority: every rider sees the same map."

  @donation_label "Support gobusgo on Ko-fi"

  @location "The location button shows where you are on the map and keeps the map on you " <>
              "as you move, until you move the map yourself. Your browser asks you first, " <>
              "and your position never leaves your browser: Gobusgo's server does not " <>
              "receive it. The browser remembers only whether you left the button on, so " <>
              "the map follows you again on your next visit. With Show my direction on, " <>
              "the dot also points the way you face or travel, from your device's compass " <>
              "or your movement. That never leaves your browser either."

  @show_direction "With this on, the dot of your location points the way you face or travel. " <>
                    "Safari on an iPhone asks for access to motion the first time you turn on " <>
                    "the location button or this setting, and a refusal is not asked again."

  @favorite_stop "Your browser remembers your favorite stops. While a page is open, " <>
                   "Gobusgo's server learns each stop only to fetch its arrivals, as for " <>
                   "any stop you open, and no usage record holds them."

  @offline_schedules "While a page is open, your browser saves the schedules of the region " <>
                       "for today and tomorrow, with the map's stops and routes, so they stay " <>
                       "on your device for offline use. It saves them after the page has " <>
                       "loaded and updates them while you are online, and turning this off " <>
                       "removes them."

  @needs_connection %{
    arrivals: "Live arrivals need a connection",
    alerts: "Service alerts need a connection",
    suggestions: "Suggestions need a connection",
    shared_vehicles: "Scooters and bikes need a connection"
  }

  # The parts of the page that need a connection, in the order the offline
  # section lists them.
  @needs_connection_order [:arrivals, :alerts, :suggestions, :shared_vehicles]

  @offline_works [
    "The map keeps the route lines, stops, and vehicles it has drawn. The vehicles stay " <>
      "where they were last seen and do not move.",
    "Your browser keeps your favorite stops, your filter, and your settings. The filter " <>
      "stays as it is until you are back online."
  ]

  @theme "Your browser remembers the theme you choose, and Match system follows the light " <>
           "or dark setting of your device while the page is open. Gobusgo's server never " <>
           "learns it."

  # Safari has no install prompt, so its offers say where its own menu adds
  # the page.
  @install_offers [
    %{
      kind: "prompt",
      text:
        "Install Gobusgo to open it from your home screen or your apps, in a window of its own."
    },
    %{
      kind: "appleHomeScreen",
      text:
        "To install Gobusgo, tap Share, then Add to Home Screen. It opens from your Home " <>
          "Screen in a window of its own."
    },
    %{
      kind: "appleDock",
      text:
        "To install Gobusgo, choose File › Add to Dock in Safari. It opens from your Dock " <>
          "in a window of its own."
    }
  ]

  @app_license %{name: "MIT License", copyright: "Copyright (c) 2026 Harriet Waters"}

  @components [
    %{name: "MapLibre GL JS", license: "BSD-3-Clause", lock_names: ["maplibre-gl"]},
    %{name: "PMTiles", license: "BSD-3-Clause", lock_names: ["pmtiles"]},
    %{
      name: "Protomaps basemap styles",
      license: "BSD-3-Clause",
      lock_names: ["@protomaps/basemaps"]
    },
    %{name: "fflate", license: "MIT", lock_names: ["fflate"]},
    %{
      name: "Noto Sans fonts and Protomaps map icons",
      license: "SIL Open Font License 1.1 for the fonts, MIT for the icons",
      lock_names: ["basemaps-assets"]
    },
    %{name: "Phoenix and Phoenix LiveView", license: "MIT", lock_names: []}
  ]

  @doc "What the application is, in one sentence."
  @spec about() :: String.t()
  def about, do: @about

  @doc "The statement that the application is independent of the agencies and the source."
  @spec disclaimer() :: String.t()
  def disclaimer, do: @disclaimer

  @doc """
  The paragraphs on how the application uses OneBusAway data, for a vehicle
  source that reads every `vehicle_interval_ms` while a map is open,
  routes that are each read every `route_period_minutes`, and an open
  stop's arrivals that are read again at an age from
  `arrival_refresh_age_ms_min` to `arrival_refresh_age_ms_max`. The interval
  and each age are a whole count of seconds, the period is a whole count of
  hours, and the longest age is over the shortest.
  """
  @spec data_use(cadences()) :: [String.t()]
  def data_use(%{
        vehicle_interval_ms: vehicle_interval_ms,
        route_period_minutes: route_period_minutes,
        arrival_refresh_age_ms_min: age_ms_min,
        arrival_refresh_age_ms_max: age_ms_max
      })
      when is_integer(vehicle_interval_ms) and is_integer(route_period_minutes) and
             is_integer(age_ms_min) and is_integer(age_ms_max) do
    Assert.condition(
      age_ms_min < age_ms_max,
      "the longest arrival refresh age must be over the shortest, " <>
        "got: #{age_ms_min} and #{age_ms_max} ms"
    )

    [
      "Vehicle positions, routes, stops, and arrival times come from the OneBusAway server " <>
        "of the Puget Sound region, which Sound Transit provides access to.",
      "While a map is open, vehicle positions are read #{seconds_text(vehicle_interval_ms)}. " <>
        "Routes and stops are read #{hours_text(route_period_minutes)}.",
      "While a stop's popup or its view in the panel is open, the arrivals at that stop " <>
        "are read every " <>
        "#{every_text(duration(age_ms_min))} to #{up_to_text(duration(age_ms_max))}, " <>
        "less often the more stops are open.",
      "Service alerts come with the vehicle positions and the arrivals: the agencies' alerts " <>
        "for the trips running now and for the stops that are open. An alert for a " <>
        "route with no vehicle running shows once one of the route's stops is open, so the " <>
        "alerts shown change as vehicles run and stops open.",
      "The map shows the data as OneBusAway supplies it. A marker stands where OneBusAway " <>
        "estimates the vehicle is, which is an estimate even for a vehicle that reported recently."
    ]
  end

  @doc """
  The paragraphs on how the application uses the shared scooter and bike
  data of `facts.operators`, each named as its operator, read from each
  operator's vehicle file, of the names in `facts.vehicle_file_names`, every
  `facts.interval_ms` while a page shows the layer and its vehicle types
  every `facts.types_period_minutes`, with raw responses kept at most
  `facts.stored_age_ms_max`. The interval is a whole count of seconds, the
  period a whole count of hours, and the age a whole count of minutes.
  """
  @spec shared_vehicles(%{
          operators: [String.t(), ...],
          vehicle_file_names: [String.t(), ...],
          interval_ms: pos_integer(),
          types_period_minutes: pos_integer(),
          stored_age_ms_max: pos_integer()
        }) :: [String.t(), ...]
  def shared_vehicles(%{
        operators: [_operator | _rest] = operators,
        vehicle_file_names: [_name | _names] = file_names,
        interval_ms: interval_ms,
        types_period_minutes: types_period_minutes,
        stored_age_ms_max: stored_age_ms_max
      })
      when is_integer(interval_ms) and is_integer(stored_age_ms_max) do
    Assert.condition(
      rem(stored_age_ms_max, @ms_per_minute) == 0,
      "the kept age must be a whole count of minutes, got: #{stored_age_ms_max} ms"
    )

    operator_text = Enum.join(operators, " and ")
    file_text = file_names |> Enum.uniq() |> Enum.join(" or ")
    minute_count = div(stored_age_ms_max, @ms_per_minute)

    [
      "Gobusgo requests #{operator_text}'s public shared vehicle feed: the file of where " <>
        "each vehicle is, #{file_text}, and the file of its vehicle types " <>
        "#{hours_text(types_period_minutes)}. A request carries no key and no data about you.",
      "It requests the vehicles only while a page shows the shared scooter and bike layer, " <>
        "#{seconds_text(interval_ms)} for every page that shows it together, and never " <>
        "while no page shows it.",
      "A page shows each vehicle's position, its form factor, and its remaining range.",
      "Gobusgo keeps each response it receives for at most #{minute_count} minutes, and the " <>
        "map tiles made from it no longer. Nothing it keeps is keyed on a vehicle's " <>
        "identifier, which the feed's format has an operator change after every trip.",
      "Your browser downloads the tiles of the area in view from Gobusgo, never " <>
        "#{operator_text}'s feed, so #{operator_text} does not learn where you look."
    ]
  end

  @doc """
  What a usage record holds of one page connection: every field of the
  record, in display order, with the sentence that says what it is.
  """
  @spec recorded() :: [recorded_field(), ...]
  def recorded, do: @recorded

  @doc """
  The statement of how long a usage record is kept, for a retention of
  `day_count` days.
  """
  @spec recorded_retention(pos_integer()) :: String.t()
  def recorded_retention(day_count) when is_integer(day_count) do
    Assert.condition(day_count >= 1, "day_count must be positive, got: #{day_count}")

    case day_count do
      1 -> "A record is kept for a day and deleted within a day after that."
      day_count -> "A record is kept for #{day_count} days and deleted within a day after that."
    end
  end

  @doc "The statement of what a usage record never holds."
  @spec recorded_never() :: String.t()
  def recorded_never, do: @recorded_never

  @doc "The statement of what donations fund and what a donation does not buy."
  @spec donation() :: String.t()
  def donation, do: @donation

  @doc "The accessible name of the donation button and the text of the donation link."
  @spec donation_label() :: String.t()
  def donation_label, do: @donation_label

  @doc "The statement of how a map page uses the rider's location."
  @spec location() :: String.t()
  def location, do: @location

  @doc "The statement of what the Show my direction setting of a map page draws."
  @spec show_direction() :: String.t()
  def show_direction, do: @show_direction

  @doc "The statement of how a map page keeps a rider's favorite stops."
  @spec favorite_stop() :: String.t()
  def favorite_stop, do: @favorite_stop

  @doc "The statement of how a map page saves schedules for offline use."
  @spec offline_schedules() :: String.t()
  def offline_schedules, do: @offline_schedules

  @doc """
  What a map page does while it is offline: `works`, the sentences of what
  still works, and `needs_connection`, one sentence per part of the page
  that needs a connection, each the text that part says in place.
  """
  @spec offline() :: %{works: [String.t()], needs_connection: [String.t()]}
  def offline do
    %{
      works: @offline_works,
      needs_connection: for(part <- @needs_connection_order, do: needs_connection(part) <> ".")
    }
  end

  @doc "The text a part of a map page says in place while the page is offline."
  @spec needs_connection(:arrivals | :alerts | :suggestions | :shared_vehicles) :: String.t()
  def needs_connection(part), do: Map.fetch!(@needs_connection, part)

  @doc "The statement of how a map page keeps a rider's theme setting."
  @spec theme() :: String.t()
  def theme, do: @theme

  @doc """
  The ways a map page offers to install the application, each with its
  `kind` and its `text`; the browser shows the one its own install offer
  calls for, or none.
  """
  @spec install_offers() :: [%{kind: String.t(), text: String.t()}, ...]
  def install_offers, do: @install_offers

  @doc "The terms the transit data is provided under, as a name and an address."
  @spec terms() :: terms()
  def terms, do: @terms

  @doc "The application's own license and its copyright line."
  @spec app_license() :: app_license()
  def app_license, do: @app_license

  @doc "Everything a page ships to the browser that has a license of its own, in display order."
  @spec components() :: [component()]
  def components, do: @components

  defp seconds_text(interval_ms) do
    Assert.condition(
      interval_ms >= @ms_per_second,
      "interval must be at least a second, got: #{interval_ms} ms"
    )

    Assert.condition(
      rem(interval_ms, @ms_per_second) == 0,
      "interval must be a whole count of seconds, got: #{interval_ms} ms"
    )

    case div(interval_ms, @ms_per_second) do
      1 -> "every second"
      second_count -> "every #{second_count} seconds"
    end
  end

  # A duration as a count of a unit: minutes where it is a whole count of
  # them, and seconds otherwise.
  defp duration(duration_ms) do
    Assert.condition(
      duration_ms >= @ms_per_second,
      "duration must be at least a second, got: #{duration_ms} ms"
    )

    Assert.condition(
      rem(duration_ms, @ms_per_second) == 0,
      "duration must be a whole count of seconds, got: #{duration_ms} ms"
    )

    case rem(duration_ms, @ms_per_minute) do
      0 -> {div(duration_ms, @ms_per_minute), "minute"}
      _remainder_ms -> {div(duration_ms, @ms_per_second), "second"}
    end
  end

  # The words after "every": "every second", "every 30 seconds".
  defp every_text({1, unit}), do: unit
  defp every_text({count, unit}), do: "#{count} #{unit}s"

  # The words after "to": "to a minute", "to 5 minutes".
  defp up_to_text({1, unit}), do: "a #{unit}"
  defp up_to_text({count, unit}), do: "#{count} #{unit}s"

  defp hours_text(period_minutes) do
    Assert.condition(
      period_minutes >= @minutes_per_hour,
      "period must be at least an hour, got: #{period_minutes} minutes"
    )

    Assert.condition(
      rem(period_minutes, @minutes_per_hour) == 0,
      "period must be a whole count of hours, got: #{period_minutes} minutes"
    )

    case div(period_minutes, @minutes_per_hour) do
      1 -> "every hour"
      @hours_per_day -> "once a day"
      hour_count -> "every #{hour_count} hours"
    end
  end
end
