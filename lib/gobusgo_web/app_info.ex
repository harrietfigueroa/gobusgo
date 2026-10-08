defmodule GobusgoWeb.AppInfo do
  @ms_per_second 1_000
  @minutes_per_hour 60
  @hours_per_day 24

  @moduledoc """
  What the info panel of a map page says about the application: what it is,
  that it is independent of the agencies, how it uses OneBusAway data,
  what it records of a page connection, the terms that data is provided under, and
  the licenses of the application and of what a page ships to the browser.
  Everything here is pure, so the cadences a text states are the ones it is
  given and a test reads every text.

  `data_use/1` states a vehicle interval in whole seconds and a route period
  in whole hours, a period of #{@hours_per_day} hours as once a day.
  """

  alias Gobusgo.Assert

  @type cadences :: %{vehicle_interval_ms: pos_integer(), route_period_minutes: pos_integer()}

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
  source that reads every `vehicle_interval_ms` while a map is open and
  routes that are each read every `route_period_minutes`. The interval is a
  whole count of seconds and the period a whole count of hours.
  """
  @spec data_use(cadences()) :: [String.t()]
  def data_use(%{
        vehicle_interval_ms: vehicle_interval_ms,
        route_period_minutes: route_period_minutes
      })
      when is_integer(vehicle_interval_ms) and is_integer(route_period_minutes) do
    [
      "Vehicle positions, routes, and stops come from the OneBusAway server of the " <>
        "Puget Sound region, which Sound Transit provides access to.",
      "While a map is open, vehicle positions are read #{seconds_text(vehicle_interval_ms)}. " <>
        "Routes and stops are read #{hours_text(route_period_minutes)}.",
      "The map shows the data as OneBusAway supplies it. A marker stands where OneBusAway " <>
        "estimates the vehicle is, which is an estimate even for a vehicle that reported recently."
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
