defmodule GobusgoWeb.AppInfoPanel do
  @moduledoc """
  The info panel of a map page, in two groups. First the rider's settings,
  under a Settings heading: how to install the application where the
  browser offers it, the theme setting, what works offline and what needs
  a connection, how schedules are saved for
  offline use, with its setting and status line, how the map is saved for
  offline use, with its setting and status line, where the basemap has an
  offline extract, and the Show my direction
  setting of the cone on the rider's location dot. Then, under an About
  heading, what the application is, a disclaimer, what donations fund where
  a donation address is configured, how to read the map, how
  OneBusAway data is used, how shared scooter and bike data is used, with
  the credit its operator's terms ask for, how the rider's location is used, how favorite
  stops are kept, what is recorded of a connection, the credits, the
  licenses, and the commit the application was built from where the build
  names one, from `GobusgoWeb.AppInfo` and the statuses of
  `GobusgoWeb.VehicleMarkers`. It sends the server no event.

  Each setting and each fact is a bold headline over a muted caption, and
  the full sentences of a topic stand behind a disclosure under it.
  """

  use Phoenix.Component

  alias Gobusgo.OneBusAway.RouteSchedule
  alias Gobusgo.Gbfs.Files
  alias Gobusgo.Gbfs.Systems
  alias Gobusgo.Gbfs.VehicleStatusRetention
  alias Gobusgo.OneBusAway.Sources
  alias Gobusgo.RetentionPolicy
  alias GobusgoWeb.AppInfo
  alias GobusgoWeb.ConnectionSignal
  alias GobusgoWeb.DonationButton
  alias GobusgoWeb.Message
  alias GobusgoWeb.VehicleMarkers

  # A route-colored status has no one color, so its swatch is a sample of
  # route colors.
  # The legend draws each status's glyph as the map draws a vehicle on a
  # red route, so a swatch keeps one route's color for every status.
  @glyph_swatches %{
    reported: %{fill: "#b91c1c", stroke: "#ffffff", dasharray: "none", ink: "#ffffff"},
    stale: %{fill: "#eec6c6", stroke: "#334155", dasharray: "none", ink: "#334155"},
    unknown: %{fill: "#eec6c6", stroke: "#334155", dasharray: "1 2", ink: "#334155"},
    scheduled: %{fill: "#ffffff", stroke: "#475569", dasharray: "3 2", ink: "#475569"}
  }

  @theme_options [
    %{value: "light", label: "Light"},
    %{value: "dark", label: "Dark"},
    %{value: "system", label: "Match system"}
  ]

  @doc """
  The panel's content. `agencies` are the agencies the panel credits, each
  with a `name`, in display order. `offline_archive` is the address and size
  of the basemap's offline extract, which the offline map setting saves, or
  `nil` for a page whose basemap has none, which offers no such setting.
  """
  attr :agencies, :list, required: true
  attr :offline_archive, :map, default: nil

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
        <.offline />
        <section
          id="app-info-offline-schedules"
          class="flex flex-col gap-2"
          phx-hook="OfflineSchedules"
          phx-update="ignore"
        >
          <.setting
            input_id="offline-schedules-enabled"
            message={AppInfo.summary(:offline_schedules)}
            checked
          />
          <p id="offline-schedules-status" data-offline-status aria-live="polite"></p>
          <.more id="app-info-offline-schedules-more" summary="How schedules are saved">
            <p>{AppInfo.offline_schedules()}</p>
          </.more>
        </section>
        <.offline_basemap :if={@offline_archive != nil} offline_archive={@offline_archive} />
        <section
          id="app-info-show-direction"
          class="flex flex-col gap-2"
          phx-hook="ShowDirection"
          phx-update="ignore"
        >
          <.setting
            input_id="show-direction-enabled"
            message={AppInfo.summary(:show_direction)}
            checked
          />
          <.more id="app-info-show-direction-more" summary="How your direction is found">
            <p>{AppInfo.show_direction()}</p>
          </.more>
        </section>
      </section>
      <section id="app-info-about" class="flex flex-col gap-5" aria-labelledby="app-info-about-title">
        <h2 id="app-info-about-title" class="text-base font-semibold">About</h2>
        <p id="app-info-what"><Message.message {AppInfo.about()} /></p>
        <section id="app-info-disclaimer" class="flex flex-col gap-2">
          <.heading message={AppInfo.summary(:disclaimer)} />
          <.more id="app-info-disclaimer-more" summary="Full disclaimer">
            <p>{AppInfo.disclaimer()}</p>
          </.more>
        </section>
        <DonationButton.section />
        <.legend />
        <.data_use />
        <.shared_vehicles />
        <section id="app-info-location" class="flex flex-col gap-2">
          <.heading message={AppInfo.summary(:location)} />
          <.more id="app-info-location-more" summary="How your location is used">
            <p>{AppInfo.location()}</p>
          </.more>
        </section>
        <section id="app-info-favorite-stop" class="flex flex-col gap-2">
          <.heading message={AppInfo.summary(:favorite_stop)} />
          <.more id="app-info-favorite-stop-more" summary="How favorites are kept">
            <p>{AppInfo.favorite_stop()}</p>
          </.more>
        </section>
        <.recorded />
        <.credits agencies={@agencies} />
        <.licenses />
      </section>
    </div>
    """
  end

  # The offline signal opens the Settings tab here and moves focus to the
  # section, which takes focus from a script alone.
  defp offline(assigns) do
    assigns =
      assign(assigns, offline: AppInfo.offline(), section_id: ConnectionSignal.section_id())

    ~H"""
    <section id={@section_id} class="flex flex-col gap-2" tabindex="-1">
      <.heading message={AppInfo.summary(:offline)} />
      <.more id="app-info-offline-more" summary="What works and what needs a connection">
        <p>Without a connection, the page shows what it already has.</p>
        <h4 class="font-medium">What works offline</h4>
        <ul id="app-info-offline-works" class="list-disc pl-5">
          <li :for={text <- @offline.works}>{text}</li>
        </ul>
        <h4 class="font-medium">What needs a connection</h4>
        <ul id="app-info-offline-needs-connection" class="list-disc pl-5">
          <li :for={text <- @offline.needs_connection}>{text}</li>
        </ul>
      </.more>
    </section>
    """
  end

  # The browser checks the stored setting, so the server renders the
  # default, off, unchecked.
  defp offline_basemap(assigns) do
    ~H"""
    <section
      id="app-info-offline-basemap"
      class="flex flex-col gap-2"
      phx-hook="OfflineBasemap"
      phx-update="ignore"
      data-archive-url={@offline_archive.url}
    >
      <.setting
        input_id="offline-basemap-enabled"
        message={AppInfo.offline_basemap_summary(@offline_archive)}
        checked={false}
      />
      <p id="offline-basemap-status" data-offline-status aria-live="polite"></p>
      <.more id="app-info-offline-basemap-more" summary="How the map is saved">
        <p>{AppInfo.offline_basemap(@offline_archive)}</p>
      </.more>
    </section>
    """
  end

  # The browser checks the stored setting, so the server renders the
  # default, Match system, checked.
  defp theme_setting(assigns) do
    assigns = assign(assigns, options: @theme_options)

    ~H"""
    <section id="app-info-theme" class="flex flex-col gap-2" phx-hook="ColorTheme" phx-update="ignore">
      <.heading message={AppInfo.summary(:theme)} />
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
      <.more id="app-info-theme-more" summary="How the theme is kept">
        <p>{AppInfo.theme()}</p>
      </.more>
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
      <h3 class="message-headline">Install Gobusgo</h3>
      <div
        :for={offer <- @offers}
        class="flex flex-col items-start gap-2"
        data-install-kind={offer.kind}
        hidden
      >
        <p class="message-caption">{offer.caption}</p>
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
    assigns =
      assign(assigns,
        statuses: VehicleMarkers.statuses(),
        tie_color: @glyph_swatches.reported.fill
      )

    ~H"""
    <section id="app-info-legend" class="flex flex-col gap-2">
      <h3 class="font-semibold">How to read the map</h3>
      <p>
        Each marker is one vehicle, drawn in its route's color. How it is drawn says how far to
        trust its position:
      </p>
      <ul class="flex flex-col gap-2 rounded-md border border-gray-300 bg-white p-3">
        <li
          :for={status <- @statuses}
          id={"app-info-status-#{status.status}"}
          class="flex items-center gap-3"
        >
          <span class="relative h-6 w-8 shrink-0" aria-hidden="true">
            <.status_glyph glyph={glyph_swatch(status.status)} />
            <.status_badge :if={status.badge} badge={status.badge} />
          </span>
          <span class="font-medium">{status.label}</span>
        </li>
      </ul>
      <ul class="flex flex-col gap-2 rounded-md border border-gray-300 bg-white p-3">
        <li id="app-info-tie-ring" class="flex items-center gap-3">
          <span class="relative h-6 w-8 shrink-0" aria-hidden="true">
            <svg class="report-tie absolute top-0 left-1 h-6 w-6" viewBox="0 0 24 24">
              <circle cx="12" cy="12" r="5" class="report-tie-paper" />
              <circle cx="12" cy="12" r="5" fill="none" stroke-width="5" class="report-tie-casing" />
              <circle cx="12" cy="12" r="5" fill="none" stroke-width="2" stroke={@tie_color} />
            </svg>
          </span>
          <span class="font-medium">Last report</span>
        </li>
        <li id="app-info-tie-line" class="flex items-center gap-3">
          <span class="relative h-6 w-8 shrink-0" aria-hidden="true">
            <svg class="report-tie absolute top-0 left-0 h-6 w-8" viewBox="0 0 32 24">
              <path d="M4 12h24" stroke-width="6" stroke-linecap="round" class="report-tie-casing" />
              <path d="M4 12h24" stroke-width="3" stroke-dasharray="4 3" stroke={@tie_color} />
            </svg>
          </span>
          <span class="font-medium">Path since the last report</span>
        </li>
      </ul>
      <p>
        A live vehicle's marker is an estimate: between reports it moves along its route at the
        schedule's pace. Zoomed in, and for the vehicle you select, a ring marks its last report
        and a dashed line joins the ring to the marker along the route.
      </p>
      <p>
        Zoomed in, a vehicle is a bus with its route's number on its shoulder and a chevron the
        way it is heading; zoomed out, a dot.
        Select a marker for its route, its destination, how far it is from its schedule, and
        its next stop. Stops appear when you zoom in.
      </p>
    </section>
    """
  end

  # A status's bus glyph, a disc with a bus on it in the status's fill,
  # outline, and ink, on a 24-unit square.
  attr :glyph, :map, required: true

  defp status_glyph(assigns) do
    ~H"""
    <svg class="status-glyph absolute top-0 left-0 h-6 w-6" viewBox="0 0 24 24">
      <circle
        cx="12"
        cy="12"
        r="10.5"
        fill={@glyph.fill}
        stroke={@glyph.stroke}
        stroke-width="2"
        stroke-dasharray={@glyph.dasharray}
      />
      <g
        fill="none"
        stroke={@glyph.ink}
        stroke-width="2.4"
        stroke-linecap="round"
        stroke-linejoin="round"
        transform="translate(5.5 5.5) scale(0.54)"
      >
        <path d="M7 3h10a2 2 0 0 1 2 2v10a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2z" />
        <path d="M5 11h14M8 21v-4M16 21v-4" />
      </g>
    </svg>
    """
  end

  # The badge of a status a recent report lacks, at the glyph's upper
  # right, as the map draws it beside a dot, on a 14-unit square in the
  # theme's badge colors.
  attr :badge, :atom, required: true

  defp status_badge(assigns) do
    ~H"""
    <svg
      class="status-badge absolute -top-1 left-4 h-3.5 w-3.5"
      viewBox="0 0 14 14"
      data-badge={@badge}
      aria-hidden="true"
    >
      <circle cx="7" cy="7" r="6.5" class="status-badge-ink" />
      <g :if={@badge == :clock} class="status-badge-stroke">
        <circle cx="7" cy="7" r="3.6" />
        <path d="M7 7V4.6M7 7l1.8 0.8" />
      </g>
      <text
        :if={@badge == :question}
        x="7"
        y="10.5"
        text-anchor="middle"
        font-size="10"
        font-weight="700"
        class="status-badge-paper"
      >
        ?
      </text>
      <g :if={@badge == :timetable} class="status-badge-stroke">
        <rect x="3.8" y="4.4" width="6.4" height="5.6" />
        <path d="M3.8 6.4h6.4M5.6 3.4V5M8.4 3.4V5" />
      </g>
    </svg>
    """
  end

  @doc """
  The fill, outline, dash of the outline, and ink of the bus glyph the
  legend draws for `status`, a status of `GobusgoWeb.VehicleMarkers`.
  """
  @spec glyph_swatch(VehicleMarkers.status()) :: %{
          fill: String.t(),
          stroke: String.t(),
          dasharray: String.t(),
          ink: String.t()
        }
  def glyph_swatch(status) when is_map_key(@glyph_swatches, status),
    do: Map.fetch!(@glyph_swatches, status)

  defp data_use(assigns) do
    {:proportional, %{interval_ms_min: age_ms_min, interval_ms_max: age_ms_max}} =
      Sources.arrival_refresh_policy()

    cadences = %{
      vehicle_interval_ms: Sources.vehicle_interval_ms_min(),
      route_period_minutes: RouteSchedule.period_minutes(),
      arrival_refresh_age_ms_min: age_ms_min,
      arrival_refresh_age_ms_max: age_ms_max
    }

    assigns =
      assign(assigns,
        facts: AppInfo.data_use_facts(cadences),
        paragraphs: AppInfo.data_use(cadences)
      )

    ~H"""
    <section
      id="app-info-data-use"
      class="flex flex-col gap-2"
      aria-labelledby="app-info-data-use-title"
    >
      <h3 id="app-info-data-use-title" class="sr-only">How OneBusAway data is used</h3>
      <p :for={fact <- @facts} class="app-info-fact"><Message.message {fact} /></p>
      <.more id="app-info-data-use-more" summary="How OneBusAway data is used">
        <p :for={paragraph <- @paragraphs}>{paragraph}</p>
      </.more>
    </section>
    """
  end

  defp shared_vehicles(assigns) do
    facts = shared_vehicle_facts()

    assigns =
      assign(assigns,
        systems: Systems.all(),
        summary: AppInfo.shared_vehicles_summary(facts.interval_ms),
        paragraphs: AppInfo.shared_vehicles(facts)
      )

    ~H"""
    <section id="app-info-shared-vehicles" class="flex flex-col gap-2">
      <.heading message={@summary} />
      <p :for={system <- @systems} id={"app-info-shared-vehicles-#{system.id}"}>
        Shared scooter and bike data is provided by {system.operator_name}, under {system.operator_name}'s <a
          href={system.terms_url}
          class="underline"
          rel="noopener"
        >{system.terms_name}</a>.
      </p>
      <.more id="app-info-shared-vehicles-more" summary="How scooter and bike data is used">
        <p :for={paragraph <- @paragraphs}>{paragraph}</p>
      </.more>
    </section>
    """
  end

  @doc """
  The facts the shared scooter and bike texts state, read from the systems,
  the file format, the configured interval, the vehicle type cadence, and
  the retention of stored responses.
  """
  @spec shared_vehicle_facts() :: map()
  def shared_vehicle_facts do
    {:ok, %{interval_ms: interval_ms}} = Gobusgo.Config.shared_vehicles()

    %{
      operators: Systems.all() |> Enum.map(& &1.operator_name) |> Enum.uniq(),
      vehicle_file_names: Enum.map(Files.versions(), &Files.vehicle_status_name/1),
      interval_ms: interval_ms,
      types_period_minutes: RouteSchedule.period_minutes(),
      stored_age_ms_max: VehicleStatusRetention.stored_age_ms_max()
    }
  end

  defp recorded(assigns) do
    day_count = RetentionPolicy.usage_day_count()

    assigns =
      assign(assigns,
        summary: AppInfo.recorded_summary(day_count),
        fields: AppInfo.recorded(),
        retention: AppInfo.recorded_retention(day_count),
        session_cookie: AppInfo.session_cookie(GobusgoWeb.Endpoint.session_cookie_age_seconds())
      )

    ~H"""
    <section id="app-info-recorded" class="flex flex-col gap-2">
      <.heading message={@summary} />
      <.more id="app-info-recorded-more" summary="What a record holds, and the cookie">
        <p>
          To count visits, Gobusgo stores one record each time a page disconnects. A record holds
          the following and nothing else:
        </p>
        <ul class="list-disc pl-5">
          <li :for={field <- @fields} id={"app-info-recorded-#{field.field}"}>{field.text}</li>
        </ul>
        <p>{AppInfo.recorded_never()}</p>
        <p id="app-info-recorded-retention">{@retention}</p>
        <p id="app-info-session-cookie">{@session_cookie}</p>
      </.more>
    </section>
    """
  end

  attr :agencies, :list, required: true

  defp credits(assigns) do
    assigns = assign(assigns, terms: AppInfo.terms())

    ~H"""
    <section id="app-info-credits" class="flex flex-col gap-2">
      <.heading message={AppInfo.summary(:credits)} />
      <.more id="app-info-credits-more" summary="Credits and data terms">
        <p>
          Transit data is provided on an "as is" basis by {agencies_text(@agencies)}, under the
          <a href={@terms.url} class="underline" rel="noopener">{@terms.name}</a>
          of Sound Transit's Open Transit Data program, and served by OneBusAway.
        </p>
        <p>
          Map data © OpenStreetMap contributors, under the Open Database License, from a
          Protomaps build.
        </p>
      </.more>
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
      <.heading message={AppInfo.license_summary()} />
      <.more id="app-info-licenses-more" summary="Licenses">
        <p>Gobusgo is offered under the {@app_license.name}. {@app_license.copyright}.</p>
        <p :if={@revision} id="app-info-revision">
          This version is built from commit <span class="break-all font-mono">{@revision}</span>.
        </p>
        <p>The page also uses:</p>
        <ul class="list-disc pl-5">
          <li :for={component <- @components}>{component.name}: {component.license}</li>
        </ul>
      </.more>
    </section>
    """
  end

  defp agencies_text([]), do: "the transit agencies of the Puget Sound region"

  defp agencies_text(agencies) do
    "the following transit agencies: " <> Enum.map_join(agencies, ", ", & &1.name)
  end

  # A section's headline, its heading, over its caption.
  attr :message, :map, required: true

  defp heading(assigns) do
    ~H"""
    <h3 class="message-headline">{@message.headline}</h3>
    <p class="message-caption">{@message.caption}</p>
    """
  end

  # A setting's checkbox, named by the headline and described by the
  # caption. The browser checks the stored setting, so the server renders
  # the default.
  attr :input_id, :string, required: true
  attr :message, :map, required: true
  attr :checked, :boolean, required: true

  defp setting(assigns) do
    ~H"""
    <div class="app-info-setting">
      <div class="flex min-w-0 flex-col">
        <label for={@input_id} class="message-headline inline-target">{@message.headline}</label>
        <p id={@input_id <> "-caption"} class="message-caption">{@message.caption}</p>
      </div>
      <input
        id={@input_id}
        type="checkbox"
        checked={@checked}
        aria-describedby={@input_id <> "-caption"}
      />
    </div>
    """
  end

  # The full sentences of a topic, behind a disclosure.
  attr :id, :string, required: true
  attr :summary, :string, required: true
  slot :inner_block, required: true

  defp more(assigns) do
    ~H"""
    <details id={@id} class="app-info-more">
      <summary class="inline-target cursor-pointer">{@summary}</summary>
      <div class="flex flex-col gap-2 pt-2">{render_slot(@inner_block)}</div>
    </details>
    """
  end
end
