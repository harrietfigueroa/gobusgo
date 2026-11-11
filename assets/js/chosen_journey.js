// The journey the rider chose, as the stop details view reads it. The
// `TripPlanner` hook writes it with `setChosenJourney` while its strip
// shows and clears it when the strip goes away, and every listener of the
// change event learns when it moves to another journey, to other texts, or
// to none. It lives in the browser alone: no server event carries it.

/** The DOM event the window gets when the chosen journey changes, with what is chosen now in its detail. */
export const CHANGE_EVENT_NAME = "gobusgo:chosen-journey-change"

/** Whether a journey is chosen. */
export const ChosenKind = Object.freeze({none: "none", journey: "journey"})

const NONE = Object.freeze({kind: ChosenKind.none})
const MINUTE_MS = 60 * 1000

let chosen = NONE

/**
 * What is chosen: `{kind: ChosenKind.journey, journey, leadText,
 * arriveText, live, serviceDayStartsMs, timeZone, names, origin, nowMs}`,
 * the router's journey with the texts of its strip, `live`, its first bus's
 * `firstRideLive` answer, the page's `names` of stops and routes, `origin`,
 * the rider's position in degrees for a journey from it or null, and
 * `nowMs`, the time the texts were written at; or `{kind: ChosenKind.none}`.
 */
export function chosenJourney() {
  return chosen
}

function isSame({earlier, later}) {
  const isJourney = earlier.journey === later.journey
  const isLead = earlier.leadText === later.leadText
  const isArrive = earlier.arriveText === later.arriveText
  const isTexts = isLead && isArrive
  const isKind = earlier.live.kind === later.live.kind
  const isLateness = earlier.live.latenessS === later.live.latenessS
  const isLive = isKind && isLateness
  const isNames = earlier.names === later.names
  const isOrigin = earlier.origin === later.origin
  const isMinute = Math.floor(earlier.nowMs / MINUTE_MS) === Math.floor(later.nowMs / MINUTE_MS)
  const isSameTexts = isJourney && isTexts
  const isSameSources = isNames && isOrigin
  const isSameLive = isLive && isMinute
  const isSameChosen = isSameTexts && isSameSources
  return isSameChosen && isSameLive
}

function announce() {
  window.dispatchEvent(new CustomEvent(CHANGE_EVENT_NAME, {detail: {chosen}}))
}

/**
 * Chooses the journey of `journey`, `live`, `leadText`, `arriveText`,
 * `serviceDayStartsMs`, `timeZone`, `names`, `origin`, and `nowMs`; a write
 * that changes nothing within the same minute of `nowMs` announces nothing.
 */
export function setChosenJourney({journey, live, leadText, arriveText, serviceDayStartsMs, timeZone, names, origin, nowMs}) {
  const next = Object.freeze({kind: ChosenKind.journey, journey, live, leadText, arriveText, serviceDayStartsMs, timeZone, names, origin, nowMs})
  const isUnchanged = chosen.kind === ChosenKind.journey && isSame({earlier: chosen, later: next})

  if (isUnchanged) {
    return
  }

  chosen = next
  announce()
}

/** Chooses none. */
export function clearChosenJourney() {
  if (chosen.kind === ChosenKind.none) {
    return
  }

  chosen = NONE
  announce()
}
