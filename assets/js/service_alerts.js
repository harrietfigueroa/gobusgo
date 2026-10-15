// What the popups show of the service alerts: a line per current alert of
// the popup's routes, which opens the alerts panel at that alert. The page
// renders the alerts of each route into an element, and a popup reads it
// when it opens, so the browser keeps none of them.

const routesElementId = "service-alert-routes"
const showModalEventName = "gobusgo:show-modal"
const lineClassName = "popup-alert"
const linePrefix = "⚠ Service alert: "
// A popup shows at most this many alert lines, then a line with the count
// of the rest, so a stop with many alerts keeps the popup's size bounded.
const lineCountMax = 2

// The current alerts of each route, by route identifier, as the page last
// rendered them; none before it has.
function alertsByRoute() {
  const element = document.getElementById(routesElementId)

  if (element === null) {
    return {}
  } else {
    return JSON.parse(element.dataset.routes)
  }
}

// The alerts of `routeIds` that apply at `stopId`, each once: an alert of a
// route as a whole, and one that names the stop. A null `stopId` takes the
// alerts of the routes as a whole alone.
function popupAlerts({routeIds, stopId}) {
  const byRoute = alertsByRoute()
  const alertsById = new Map()

  for (const routeId of routeIds) {
    for (const alert of byRoute[routeId] ?? []) {
      if (alert.stop_ids.length === 0 || alert.stop_ids.includes(stopId)) {
        alertsById.set(alert.id, alert)
      }
    }
  }

  return [...alertsById.values()]
}

// Opens the alerts panel and, for an alert it lists, shows that alert with
// its details open.
function openPanel(alertId) {
  const panel = document.getElementById(document.getElementById(routesElementId).dataset.panelId)
  panel.dispatchEvent(new CustomEvent(showModalEventName, {bubbles: true}))

  const entry = [...panel.querySelectorAll("[data-alert-id]")]
    .find((element) => element.dataset.alertId === alertId)

  if (entry !== undefined) {
    const details = entry.querySelector("details")

    if (details !== null) {
      details.open = true
    }

    entry.scrollIntoView({block: "start"})
  }
}

// A line of a popup, built as text: an alert's summary comes from outside
// the application and is never parsed as HTML.
function line(text, alertId) {
  const button = document.createElement("button")
  button.type = "button"
  button.className = lineClassName
  button.textContent = text
  button.title = text
  button.addEventListener("click", () => openPanel(alertId))
  return button
}

// The lines a popup of `routeIds` at `stopId` shows for their current
// alerts, none when they have none.
export function alertLines({routeIds, stopId}) {
  const alerts = popupAlerts({routeIds, stopId})
  const lines = alerts.slice(0, lineCountMax).map((alert) => line(linePrefix + alert.summary, alert.id))
  const restCount = alerts.length - lines.length

  if (restCount > 0) {
    lines.push(line(`⚠ ${restCount} more service alert${restCount === 1 ? "" : "s"}`, null))
  }

  return lines
}

// The hook of a <time> element: writes its moment in the browser's own
// time zone, which the server, holding no time zone data, cannot.
export const LocalTime = {
  mounted() { this.write() },
  updated() { this.write() },

  write() {
    const moment = new Date(this.el.getAttribute("datetime"))

    this.el.textContent = moment.toLocaleString(undefined, {
      weekday: "short",
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit"
    })
  }
}
