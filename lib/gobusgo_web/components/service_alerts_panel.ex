defmodule GobusgoWeb.ServiceAlertsPanel do
  @moduledoc """
  The service alerts of a map page, from `GobusgoWeb.ServiceAlerts`: a
  button over the map with the count of current alerts, the panel it opens,
  and an element that shows nothing and carries the current alerts of each
  route for the popups.

  The panel is a `<dialog>` the browser opens and closes, as the info panel
  is. It lists the current alerts, then the upcoming ones with the start of
  each, each with its summary, its routes, its description behind a
  disclosure, and its link. The button shows while the page has an alert,
  current or upcoming. An alert's element carries its identifier in
  `data-alert-id`, so a popup line can open the panel at it.

  The popups' element carries the routes' alerts as JSON in `data-routes`.
  A patch changes it only when the alerts change, and a page that connects
  again renders it again, so the browser reads it when a popup opens and
  keeps none of it.
  """

  use Phoenix.Component

  alias GobusgoWeb.ServiceAlerts
  alias Phoenix.LiveView.JS

  @panel_id "service-alerts"
  @show_event "gobusgo:show-modal"

  @doc "The panel's identifier, which the popups open the panel by."
  @spec panel_id() :: String.t()
  def panel_id, do: @panel_id

  @doc "The button, the panel, and the popups' element. `alerts` is what `GobusgoWeb.ServiceAlerts.alerts/1` returns."
  attr :alerts, :map, required: true

  def panel(assigns) do
    assigns =
      assign(assigns,
        panel_id: @panel_id,
        show: JS.dispatch(@show_event, to: "#" <> @panel_id),
        current_count: length(assigns.alerts.current),
        shown: assigns.alerts.current != [] or assigns.alerts.upcoming != [],
        upcoming_day_count: ServiceAlerts.upcoming_day_count()
      )

    ~H"""
    <button
      :if={@shown}
      id="service-alerts-open"
      type="button"
      aria-label={button_label(@current_count)}
      aria-haspopup="dialog"
      phx-click={@show}
      class="surface fixed bottom-2 left-14 z-10 flex h-11 items-center gap-1 px-3 [--surface-radius:9999px] text-sm font-semibold shadow"
    >
      <span aria-hidden="true">⚠</span>
      <span :if={@current_count > 0} id="service-alerts-count">{@current_count}</span>
    </button>

    <div
      id="service-alert-routes"
      data-panel-id={@panel_id}
      data-routes={JSON.encode!(@alerts.routes)}
      hidden
    >
    </div>

    <dialog
      id={@panel_id}
      aria-labelledby="service-alerts-title"
      phx-mounted={JS.ignore_attributes("open")}
      class="m-auto max-h-[85vh] w-[min(36rem,calc(100vw-2rem))] overflow-y-auto surface p-0 text-sm text-slate-900 shadow-lg backdrop:bg-black/40"
    >
      <header class="sticky top-0 flex items-center justify-between border-b border-gray-300 bg-[var(--surface-fill)] px-4 py-3">
        <h2 id="service-alerts-title" class="text-base font-semibold">Service alerts</h2>
        <form method="dialog">
          <button class="close-button [--close-button-size:32px]" aria-label="Close"></button>
        </form>
      </header>

      <div class="flex flex-col gap-5 px-4 py-4">
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
    </dialog>
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
        <summary class="cursor-pointer">Details</summary>
        <p class="mt-1 whitespace-pre-line">{@alert.description}</p>
      </details>
      <a :if={@alert.url} href={@alert.url} class="underline" rel="noopener">More from the agency</a>
    </article>
    """
  end

  defp button_label(0), do: "Service alerts"
  defp button_label(1), do: "Service alerts: 1 now"
  defp button_label(count), do: "Service alerts: #{count} now"

  defp routes_text([route_name]), do: "Route: " <> route_name
  defp routes_text(route_names), do: "Routes: " <> Enum.join(route_names, ", ")
end
