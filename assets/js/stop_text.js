// The texts of the stop view in the glanceable style, as pure functions of a
// stop's texts and its arrivals' age. Nothing here reads the document.

/** Whether a pill is shown, with its mark and its text, or absent. */
export const PillKind = Object.freeze({shown: "shown", absent: "absent"})

// The arrow and the word of each compass direction OneBusAway gives a stop.
// https://developer.onebusaway.org/api/where/elements/stop — checked 2026-11-09
const directions = Object.freeze({
  N: {mark: "↑", text: "North"},
  NE: {mark: "↗", text: "Northeast"},
  E: {mark: "→", text: "East"},
  SE: {mark: "↘", text: "Southeast"},
  S: {mark: "↓", text: "South"},
  SW: {mark: "↙", text: "Southwest"},
  W: {mark: "←", text: "West"},
  NW: {mark: "↖", text: "Northwest"}
})

function isText(value) {
  return typeof value === "string" && value !== ""
}

/**
 * The pill of a stop's `direction`: the arrow and the word of a compass
 * direction, the text alone of any other, and absent for none.
 */
export function directionPill(direction) {
  if (!isText(direction)) {
    return {kind: PillKind.absent}
  }

  if (Object.hasOwn(directions, direction)) {
    return {kind: PillKind.shown, ...directions[direction]}
  }

  return {kind: PillKind.shown, mark: "", text: direction}
}

/** The pill of a stop's `code`, "#" before it, and absent for none. */
export function codePill(code) {
  if (!isText(code)) {
    return {kind: PillKind.absent}
  }

  return {kind: PillKind.shown, mark: "#", text: code}
}

function updatedText(ageMinutes) {
  if (ageMinutes >= 1) {
    return `${ageMinutes} min ago`
  }

  return "now"
}

/**
 * The key under a stop's arrivals: the line shown beside a live dot, and the
 * sentences a screen reader reads in its place. The server's arrivals are
 * from a fetch `ageMinutes` old; the saved schedules' are all scheduled.
 */
export function arrivalsKey({ageMinutes, isScheduled}) {
  if (isScheduled) {
    return {
      shown: "scheduled times from the saved schedules",
      spoken: "Scheduled times from the saved schedules."
    }
  }

  const updated = updatedText(ageMinutes)

  return {
    shown: `live · plain = scheduled · updated ${updated}`,
    spoken: `Times with a dot are live; plain times are scheduled. Updated ${updated}.`
  }
}
