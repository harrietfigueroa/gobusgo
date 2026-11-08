defmodule GobusgoWeb.AppInfoPanel do
  @moduledoc """
  The info panel of a map page, in two groups. First the rider's settings,
  under a Settings heading: how to install the application where the
  browser offers it, the theme setting, how schedules are saved for
  offline use, with its setting and status line, and the Show my direction
  setting of the cone on the rider's location dot. Then, under an About
  heading, what the application is, a disclaimer, what donations fund where
  a donation address is configured, how to read the map, how
  OneBusAway data is used, how the rider's location is used, how favorite
  stops are kept, what is recorded of a connection, the credits, the
  licenses, and the commit the application was built from where the build
  names one, from `GobusgoWeb.AppInfo` and the statuses of
  `GobusgoWeb.VehicleMarkers`. It sends the server no event.
  """

  use Phoenix.Component

  alias Gobusgo.OneBusAway.RouteSchedule
  alias Gobusgo.OneBusAway.Sources
  alias Gobusgo.RetentionPolicy
  alias GobusgoWeb.AppInfo
  alias GobusgoWeb.DonationButton
  alias GobusgoWeb.VehicleMarkers

  # A route-colored status has no one color, so its swatch is a sample of
  # route colors.
  @route_color_sample "linear-gradient(135deg, #2563eb, #e11d48, #16a34a)"

  @theme_options [
    %{value: "light", label: "Light"},
    %{value: "dark", label: "Dark"},
    %{value: "system", label: "Match system"}
  ]

  @doc """
  The panel's content. `agencies` are the agencies the panel credits, each
  with a `name`, in display order.
  """
  attr :agencies, :list, required: true

  def content(assigns) do
    ~H"""
    <div id="app-info" class="flex flex-col gap-8">
      <section
        id="app-info-settings"
        class="flex flex-col gap-5"
        aria-labelledby="app-info-settings-title"
      >
        <h2 id="app-info-settings-title" class="text-base font-semibold">Settings</h2>
        <.install_app />
        <.theme_setting />
        <section
          id="app-info-offline-schedules"
          class="flex flex-col gap-2"
          phx-hook="OfflineSchedules"
          phx-update="ignore"
        >
          <h3 class="font-semibold">Offline schedules</h3>
          <p>{AppInfo.offline_schedules()}</p>
          <label class="flex items-center gap-2">
            <input id="offline-schedules-enabled" type="checkbox" checked />
            Save schedules for offline use
          </label>
          <p id="offline-schedules-status" data-offline-status aria-live="polite"></p>
        </section>
        <section
          id="app-info-show-direction"
          class="flex flex-col gap-2"
          phx-hook="ShowDirection"
          phx-update="ignore"
        >
          <h3 class="font-semibold">Your direction</h3>
          <p>{AppInfo.show_direction()}</p>
          <label class="flex items-center gap-2">
            <input id="show-direction-enabled" type="checkbox" checked /> Show my direction
          </label>
        </section>
      </section>
      <section id="app-info-about" class="flex flex-col gap-5" aria-labelledby="app-info-about-title">
        <h2 id="app-info-about-title" class="text-base font-semibold">About</h2>
        <p>{AppInfo.about()}</p>
        <section id="app-info-disclaimer" class="flex flex-col gap-2">
          <h3 class="font-semibold">Disclaimer</h3>
          <p>{AppInfo.disclaimer()}</p>
        </section>
        <DonationButton.section />
        <.legend />
        <.data_use />
        <section id="app-info-location" class="flex flex-col gap-2">
          <h3 class="font-semibold">Your location</h3>
          <p>{AppInfo.location()}</p>
        </section>
        <section id="app-info-favorite-stop" class="flex flex-col gap-2">
          <h3 class="font-semibold">Your favorite stops</h3>
          <p>{AppInfo.favorite_stop()}</p>
        </section>
        <.recorded />
        <.credits agencies={@agencies} />
        <.licenses />
      </section>
    </div>
    """
  end

  # The browser checks the stored setting, so the server renders the
  # default, Match system, checked.
  defp theme_setting(assigns) do
    assigns = assign(assigns, options: @theme_options)

    ~H"""
    <section id="app-info-theme" class="flex flex-col gap-2" phx-hook="ColorTheme" phx-update="ignore">
      <h3 class="font-semibold">Theme</h3>
      <p>{AppInfo.theme()}</p>
      <fieldset class="theme-options">
        <legend class="sr-only">Theme</legend>
        <label :for={option <- @options} class="theme-option">
          <input
            id={"theme-setting-#{option.value}"}
            type="radio"
            name="theme"
            value={option.value}
            checked={option.value == "system"}
          />
          {option.label}
        </label>
      </fieldset>
      <p id="theme-setting-status" data-theme-status aria-live="polite"></p>
    </section>
    """
  end

  # The browser decides which offer applies, or none, as in an installed
  # app, so the server renders the section and every offer hidden.
  defp install_app(assigns) do
    assigns = assign(assigns, offers: AppInfo.install_offers())

    ~H"""
    <section
      id="app-info-install"
      class="flex flex-col gap-2"
      phx-hook="InstallApp"
      phx-update="ignore"
      hidden
    >
      <h3 class="font-semibold">Install app</h3>
      <div
        :for={offer <- @offers}
        class="flex flex-col items-start gap-2"
        data-install-kind={offer.kind}
        hidden
      >
        <p>{offer.text}</p>
        <button
          :if={offer.kind == "prompt"}
          type="button"
          class="surface px-3 py-1 font-semibold"
          data-install-button
        >
          Install app
        </button>
      </div>
    </section>
    """
  end

  defp legend(assigns) do
    assigns = assign(assigns, statuses: VehicleMarkers.statuses())

    ~H"""
    <section id="app-info-legend" class="flex flex-col gap-2">
      <h3 class="font-semibold">How to read the map</h3>
      <p>
        Each marker is one vehicle, drawn in its route's color. How it is drawn says how far to
        trust its position:
      </p>
      <dl class="flex flex-col gap-2 rounded-md border border-gray-300 bg-white p-3">
        <div
          :for={status <- @statuses}
          id={"app-info-status-#{status.status}"}
          class="flex items-start gap-2"
        >
          <span class="mt-1 h-3 w-3 shrink-0 rounded-full" style={swatch_style(status)}></span>
          <div>
            <dt class="font-medium">{status.label}</dt>
            <dd>{status.description}</dd>
          </div>
        </div>
      </dl>
      <p>
        A pointed marker shows the way the vehicle is heading, and a round one has no heading.
        Select a marker for its route, its destination, how far it is from its schedule, and
        its next stop. Stops appear when you zoom in.
      </p>
    </section>
    """
  end

  @doc """
  Returns the inline style of the legend's swatch for `definition`, a status
  definition of `GobusgoWeb.VehicleMarkers`: its own color, or a sample of
  route colors for a status drawn in its route's color, at its opacity.
  """
  @spec swatch_style(VehicleMarkers.status_definition()) :: String.t()
  def swatch_style(%{color: nil, opacity: opacity}) when is_float(opacity) do
    "background-image: #{@route_color_sample}; opacity: #{opacity}"
  end

  def swatch_style(%{color: color, opacity: opacity})
      when is_binary(color) and is_float(opacity) do
    "background-color: #{color}; opacity: #{opacity}"
  end

  defp data_use(assigns) do
    {:proportional, %{interval_ms_min: age_ms_min, interval_ms_max: age_ms_max}} =
      Sources.arrival_refresh_policy()

    assigns =
      assign(assigns,
        paragraphs:
          AppInfo.data_use(%{
            vehicle_interval_ms: Sources.vehicle_interval_ms_min(),
            route_period_minutes: RouteSchedule.period_minutes(),
            arrival_refresh_age_ms_min: age_ms_min,
            arrival_refresh_age_ms_max: age_ms_max
          })
      )

    ~H"""
    <section id="app-info-data-use" class="flex flex-col gap-2">
      <h3 class="font-semibold">How OneBusAway data is used</h3>
      <p :for={paragraph <- @paragraphs}>{paragraph}</p>
    </section>
    """
  end

  defp recorded(assigns) do
    assigns =
      assign(assigns,
        fields: AppInfo.recorded(),
        retention: AppInfo.recorded_retention(RetentionPolicy.usage_day_count())
      )

    ~H"""
    <section id="app-info-recorded" class="flex flex-col gap-2">
      <h3 class="font-semibold">What is recorded</h3>
      <p>
        To count visits, Gobusgo stores one record each time a page disconnects. A record holds
        the following and nothing else:
      </p>
      <ul class="list-disc pl-5">
        <li :for={field <- @fields} id={"app-info-recorded-#{field.field}"}>{field.text}</li>
      </ul>
      <p>{AppInfo.recorded_never()}</p>
      <p id="app-info-recorded-retention">{@retention}</p>
    </section>
    """
  end

  attr :agencies, :list, required: true

  defp credits(assigns) do
    assigns = assign(assigns, terms: AppInfo.terms())

    ~H"""
    <section id="app-info-credits" class="flex flex-col gap-2">
      <h3 class="font-semibold">Credits</h3>
      <p>
        Transit data is provided on an "as is" basis by {agencies_text(@agencies)}, under the
        <a href={@terms.url} class="underline" rel="noopener">{@terms.name}</a>
        of Sound Transit's Open Transit Data program, and served by OneBusAway.
      </p>
      <p>
        Map data © OpenStreetMap contributors, under the Open Database License, from a
        Protomaps build.
      </p>
    </section>
    """
  end

  defp licenses(assigns) do
    {:ok, revision} = Gobusgo.Config.revision()

    assigns =
      assign(assigns,
        app_license: AppInfo.app_license(),
        components: AppInfo.components(),
        revision: revision
      )

    ~H"""
    <section id="app-info-licenses" class="flex flex-col gap-2">
      <h3 class="font-semibold">License</h3>
      <p>Gobusgo is offered under the {@app_license.name}. {@app_license.copyright}.</p>
      <p :if={@revision} id="app-info-revision">
        This version is built from commit <span class="break-all font-mono">{@revision}</span>.
      </p>
      <p>The page also uses:</p>
      <ul class="list-disc pl-5">
        <li :for={component <- @components}>{component.name}: {component.license}</li>
      </ul>
    </section>
    """
  end

  defp agencies_text([]), do: "the transit agencies of the Puget Sound region"

  defp agencies_text(agencies) do
    "the following transit agencies: " <> Enum.map_join(agencies, ", ", & &1.name)
  end
end
