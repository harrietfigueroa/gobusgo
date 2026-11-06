// The texts of a stop's arrivals, as the server sends them with the
// "stop-arrivals:arrivals" event.

const arrivalsHeading = "Arrivals"
const arrivalsWaiting = "Waiting for this stop's arrivals"
const arrivalsNone = "No arrivals soon"
const arrivalsRefused = "No arrivals for this stop"
const arrivalsBusy = "Too many stops open; close one to see this stop's arrivals"
const arrivalNow = "now"
const arrivalScheduledNote = " (scheduled)"
const arrivalUnnamed = "Arrival"

export function appendParagraph(element, text) {
  const paragraph = document.createElement("p")
  paragraph.textContent = text
  element.appendChild(paragraph)
}

// One arrival as a line: where it goes, and how soon. A time that is the
// schedule and no prediction says so.
function arrivalText({route, headsign, minutes, predicted}) {
  const names = []

  if (typeof route === "string") {
    names.push(route)
  }

  if (typeof headsign === "string") {
    names.push(`to ${headsign}`)
  }

  const name = names.length === 0 ? arrivalUnnamed : names.join(" ")
  const time = minutes === 0 ? arrivalNow : `${minutes} min`
  const note = predicted ? "" : arrivalScheduledNote

  return `${name}: ${time}${note}`
}

// The heading of a stop's arrivals, with the age of the fetch they come
// from once it is a minute old.
function arrivalsHeadingText(ageMinutes) {
  if (ageMinutes >= 1) {
    return `${arrivalsHeading} (as of ${ageMinutes} min ago)`
  } else {
    return arrivalsHeading
  }
}

// The lines a popup shows for what the server says of its stop's arrivals.
function arrivalsLines({status, age_minutes: ageMinutes, arrivals}) {
  switch (status) {
    case "waiting":
      return [arrivalsWaiting]
    case "refused":
      return [arrivalsRefused]
    case "busy":
      return [arrivalsBusy]
    case "arrivals":
      if (arrivals.length === 0) {
        return [arrivalsHeadingText(ageMinutes), arrivalsNone]
      } else {
        return [arrivalsHeadingText(ageMinutes), ...arrivals.map(arrivalText)]
      }
    default:
      throw new Error(`unknown arrivals status: ${status}`)
  }
}

// Writes a stop's arrivals into `element` as text nodes: the names come
// from outside the application and are never parsed as HTML.
export function writeArrivals(element, shown) {
  element.replaceChildren()

  for (const line of arrivalsLines(shown)) {
    appendParagraph(element, line)
  }
}
