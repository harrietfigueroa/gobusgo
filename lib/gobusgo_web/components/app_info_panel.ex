defmodule GobusgoWeb.AppInfoPanel do
  @moduledoc """
  The info button of a map page and the panel it opens: what the
  application is, a disclaimer, how to read the map, how OneBusAway data is used, the
  credits, and the licenses, from `GobusgoWeb.AppInfo` and the statuses of
  `GobusgoWeb.VehicleMarkers`.

  The panel is a `<dialog>` the browser opens and closes. The button
  dispatches the `gobusgo:show-modal` DOM event to the panel, and the form
  inside the panel closes it, so neither sends the server an event. The
  panel's `open` attribute is the browser's: a patch of the page leaves it
  as it is, so a panel a rider has open stays open.
  """

  use Phoenix.Component

  alias Gobusgo.OneBusAway.RouteSchedule
  alias Gobusgo.OneBusAway.Sources
  alias GobusgoWeb.AppInfo
  alias GobusgoWeb.VehicleMarkers
  alias Phoenix.LiveView.JS

  @panel_id "app-info"
  @show_event "gobusgo:show-modal"

  @doc """
  The button and the panel. `agencies` are the agencies the panel credits,
  each with a `name`, in display order.
  """
  attr :agencies, :list, required: true

  def panel(assigns) do
    assigns =
      assign(assigns, panel_id: @panel_id, show: JS.dispatch(@show_event, to: "#" <> @panel_id))

    ~H"""
    <button
      id="app-info-open"
      type="button"
      aria-label="About this map"
      aria-haspopup="dialog"
      phx-click={@show}
      class="fixed bottom-2 left-2 z-10 h-9 w-9 rounded-full bg-white text-lg font-semibold shadow"
    >
      i
    </button>

    <dialog
      id={@panel_id}
      aria-labelledby="app-info-title"
      phx-mounted={JS.ignore_attributes("open")}
      class="m-auto max-h-[85vh] w-[min(36rem,calc(100vw-2rem))] overflow-y-auto rounded bg-white p-0 text-sm text-slate-900 shadow-lg backdrop:bg-black/40"
    >
      <header class="sticky top-0 flex items-center justify-between border-b bg-white px-4 py-3">
        <h2 id="app-info-title" class="text-base font-semibold">About Gobusgo</h2>
        <form method="dialog">
          <button class="rounded border px-2 py-1">Close</button>
        </form>
      </header>

      <div class="flex flex-col gap-5 px-4 py-4">
        <p>{AppInfo.about()}</p>
        <section id="app-info-disclaimer" class="flex flex-col gap-2">
          <h3 class="font-semibold">Disclaimer</h3>
          <p>{AppInfo.disclaimer()}</p>
        </section>
        <.legend />
        <.data_use />
        <.credits agencies={@agencies} />
        <.licenses />
      </div>
    </dialog>
    """
  end

  defp legend(assigns) do
    assigns = assign(assigns, statuses: VehicleMarkers.statuses())

    ~H"""
    <section class="flex flex-col gap-2">
      <h3 class="font-semibold">How to read the map</h3>
      <p>Each marker is one vehicle. Its color says how far to trust its position:</p>
      <dl class="flex flex-col gap-2">
        <div
          :for={status <- @statuses}
          id={"app-info-status-#{status.status}"}
          class="flex items-start gap-2"
        >
          <span class="mt-1 h-3 w-3 shrink-0 rounded-full" style={"background-color: #{status.color}"}></span>
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

  defp data_use(assigns) do
    assigns =
      assign(assigns,
        paragraphs:
          AppInfo.data_use(%{
            vehicle_interval_ms: Sources.vehicle_interval_ms_min(),
            route_period_minutes: RouteSchedule.period_minutes()
          })
      )

    ~H"""
    <section class="flex flex-col gap-2">
      <h3 class="font-semibold">How OneBusAway data is used</h3>
      <p :for={paragraph <- @paragraphs}>{paragraph}</p>
    </section>
    """
  end

  attr :agencies, :list, required: true

  defp credits(assigns) do
    assigns = assign(assigns, terms: AppInfo.terms())

    ~H"""
    <section class="flex flex-col gap-2">
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
    assigns =
      assign(assigns, app_license: AppInfo.app_license(), components: AppInfo.components())

    ~H"""
    <section class="flex flex-col gap-2">
      <h3 class="font-semibold">License</h3>
      <p>Gobusgo is offered under the {@app_license.name}. {@app_license.copyright}.</p>
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
