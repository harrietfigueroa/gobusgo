// The texts of a vehicle's details view as labels, as pure functions of the
// texts its marker carries: the route as the title, a muted line of where it
// goes and which vehicle it is, key-value rows of its status, the age of its
// last report, where its marker stands, its lateness, and its next stop, and
// a muted note on where its marker stands. Nothing here reads the document.

import {unreachable} from "./assert.js"
import {MarkerPositionKind} from "./vehicle_motion.js"

const PART_SEPARATOR = " · "
const AGENCY_SEPARATOR = "_"
const AGE_SUFFIX = " ago"
const SCHEDULED_TRIP_TEXT = "scheduled trip"
const SCHEDULED_POSITION_NOTE = "Position is the saved schedule's; delays, cancellations, and detours are unknown."

function isText(value) {
  return typeof value === "string" && value !== ""
}

/** The short form of a status's legend label: its first part, "Stale" of "Stale · over 2 min". */
export function shortStatusLabel(label) {
  const [first] = label.split(PART_SEPARATOR)
  return first
}

// The vehicle's own number, without the agency OneBusAway names it under.
// https://developer.onebusaway.org/api/where/elements/agency-and-id — checked 2026-11-09
function vehicleNumber(vehicleId) {
  const separatorIndex = vehicleId.indexOf(AGENCY_SEPARATOR)
  return vehicleId.slice(separatorIndex + 1)
}

function vehicleText({vehicleId, isScheduledTrip}) {
  if (isScheduledTrip) {
    return SCHEDULED_TRIP_TEXT
  }

  return `bus ${vehicleNumber(vehicleId)}`
}

function capitalized(text) {
  return text.charAt(0).toUpperCase() + text.slice(1)
}

// The value of the Position row and the note under the rows, by where the
// marker stands.
function positionTexts(position) {
  switch (position) {
    case MarkerPositionKind.estimated:
      return {
        value: "Estimated",
        note: "The marker is an estimate: it moves along the route at the schedule's pace from the last report, which the ring marks."
      }
    case MarkerPositionKind.lastReport:
      return {value: "At last report", note: "The marker stands at the last report."}
    case MarkerPositionKind.fetched:
      return {value: "Source's estimate", note: "The marker stands where the source estimates the vehicle is."}
    default:
      return unreachable(position, "a marker stands somewhere")
  }
}

/**
 * A vehicle's view: the route as the title, or its headsign, or the vehicle
 * for one with neither; a muted line of "To" its headsign, where the title
 * is not the headsign, and the vehicle; the rows of its status, the age of
 * its last report, where its marker stands, `position`, a
 * `MarkerPositionKind`, its lateness, and its next stop, each where the
 * marker has it; and the note on where its marker stands. A saved
 * schedule's trip names no position row, and its note says what the saved
 * schedule leaves out.
 */
export function vehicleViewText({route, headsign, vehicleId, statusLabel, locationAge, schedule, nextStop, isScheduledTrip, position}) {
  const vehicle = vehicleText({vehicleId, isScheduledTrip})
  const meta = []
  let title = capitalized(vehicle)

  if (isText(route)) {
    title = route

    if (isText(headsign)) {
      meta.push(`To ${headsign}`)
    }

    meta.push(vehicle)
  } else if (isText(headsign)) {
    title = headsign
    meta.push(vehicle)
  }

  const rows = [{key: "Status", value: shortStatusLabel(statusLabel)}]
  const isAge = isText(locationAge) && locationAge.endsWith(AGE_SUFFIX)

  if (isAge) {
    rows.push({key: "Last reported", value: locationAge})
  }

  const positionText = positionTexts(position)
  let note = SCHEDULED_POSITION_NOTE

  if (!isScheduledTrip) {
    rows.push({key: "Position", value: positionText.value})
    note = positionText.note
  }

  if (isText(schedule)) {
    rows.push({key: "Schedule", value: schedule})
  }

  if (isText(nextStop)) {
    rows.push({key: "Next stop", value: nextStop})
  }

  return {title, meta: meta.join(PART_SEPARATOR), rows, note}
}
