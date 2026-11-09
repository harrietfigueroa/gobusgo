defmodule GobusgoWeb.ServiceAlertsPanel do
  @moduledoc """
  The service alerts of a map page, from `GobusgoWeb.ServiceAlerts`: the
  panel that lists them, and an element that shows nothing and carries the
  current alerts of each route for the popups.

  The panel lists the current alerts, then the upcoming ones with the start
  of each, each with its summary, its routes, its description behind a
  disclosure, and its link. An alert's element carries its identifier in
  `data-alert-id`, so a popup line can open the panel at it. While the page
  is offline the stylesheet hides the alerts and shows the note that
  service alerts need a connection.

  The popups' element carries the routes' alerts as JSON in `data-routes`.
  A patch changes it only when the alerts change, and a page that connects
  again renders it again, so the browser reads it when a popup opens and
  keeps none of it.
  """

  use Phoenix.Component

  alias GobusgoWeb.AppInfo
  alias GobusgoWeb.ServiceAlerts
  alias Phoenix.LiveView.JS

  @panel_id "service-alerts"

  @doc "The panel's identifier, which the popups open the panel by."
  @spec panel_id() :: String.t()
  def panel_id, do: @panel_id

  @doc "The panel and the popups' element. `alerts` is what `GobusgoWeb.ServiceAlerts.alerts/1` returns."
  attr :alerts, :map, required: true

  def content(assigns) do
    assigns =
      assign(assigns,
        panel_id: @panel_id,
        upcoming_day_count: ServiceAlerts.upcoming_day_count()
      )

    ~H"""
    <div
      id="service-alert-routes"
      data-panel-id={@panel_id}
      data-routes={JSON.encode!(@alerts.routes)}
      hidden
    >
    </div>

    <div id={@panel_id} class="flex flex-col gap-5">
      <h2 class="text-base font-semibold">Service alerts</h2>
      <p class="offline-note">{AppInfo.needs_connection(:alerts)}</p>
      <div class="needs-connection flex flex-col gap-5">
        <p>
          The agencies' alerts for the trips running now and for the stops open on the map, for
          the routes the filter shows.
        </p>

        <section id="service-alerts-current" class="flex flex-col gap-3">
          <h3 class="font-semibold">Now</h3>
          <p :if={@alerts.current == []}>No alerts now.</p>
          <.entry :for={alert <- @alerts.current} alert={alert} />
        </section>

        <section id="service-alerts-upcoming" class="flex flex-col gap-3">
          <h3 class="font-semibold">In the next {@upcoming_day_count} days</h3>
          <p :if={@alerts.upcoming == []}>No upcoming alerts.</p>
          <.entry :for={alert <- @alerts.upcoming} alert={alert} />
        </section>
      </div>
    </div>
    """
  end

  attr :alert, :map, required: true

  defp entry(assigns) do
    ~H"""
    <article
      id={@alert.dom_id}
      data-alert-id={@alert.id}
      class="flex scroll-mt-16 flex-col gap-1 rounded-md border border-gray-300 bg-white p-3"
    >
      <p :if={@alert.starts_at} class="font-medium">
        From
        <time
          id={@alert.dom_id <> "-start"}
          phx-hook="LocalTime"
          datetime={DateTime.to_iso8601(@alert.starts_at)}
        >
          {Calendar.strftime(@alert.starts_at, "%a %b %-d, %H:%M UTC")}
        </time>
      </p>
      <p>{@alert.summary}</p>
      <p class="text-slate-600">{routes_text(@alert.route_names)}</p>
      <details
        :if={@alert.description}
        id={@alert.dom_id <> "-details"}
        phx-mounted={JS.ignore_attributes("open")}
      >
        <summary class="inline-target cursor-pointer">Details</summary>
        <p class="mt-1 whitespace-pre-line">{@alert.description}</p>
      </details>
      <a :if={@alert.url} href={@alert.url} class="inline-target underline" rel="noopener">
        More from the agency
      </a>
    </article>
    """
  end

  defp routes_text([route_name]), do: "Route: " <> route_name
  defp routes_text(route_names), do: "Routes: " <> Enum.join(route_names, ", ")
end
