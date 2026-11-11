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

let chosen = NONE

/**
 * What is chosen: `{kind: ChosenKind.journey, journey, leadText,
 * arriveText, live, serviceDayStartsMs, timeZone}`, the router's journey
 * with the texts of its strip and `live`, its first bus's
 * `firstRideLive` answer, or `{kind: ChosenKind.none}`.
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
  const isSameTexts = isJourney && isTexts
  return isSameTexts && isLive
}

function announce() {
  window.dispatchEvent(new CustomEvent(CHANGE_EVENT_NAME, {detail: {chosen}}))
}

/** Chooses the journey of `journey`, `live`, `leadText`, `arriveText`, `serviceDayStartsMs`, and `timeZone`; a write that changes nothing announces nothing. */
export function setChosenJourney({journey, live, leadText, arriveText, serviceDayStartsMs, timeZone}) {
  const next = Object.freeze({kind: ChosenKind.journey, journey, live, leadText, arriveText, serviceDayStartsMs, timeZone})
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
