// What the offline signal says. Everything here is pure: the saved index of
// the offline schedules, the time, and the connection states are given as
// values, so the signal's message and its announcements are functions of them.
//
// The signal's headline says the page is offline, and its caption what the
// map shows and how old the saved schedules are: by their newest build while
// a saved date is current, and by when they were saved once every date has
// ended.

import {assertCondition, unreachable} from "./core/assert.js"
import {ConnectionKind} from "./connection_rules.js"
import {IndexKind} from "./core/offline_bundle.js"

/** How often an offline page writes the signal's age again. */
export const AGE_REFRESH_MS = 60 * 1000

const MINUTE_MS = 60 * 1000
const HOUR_MS = 60 * 60 * 1000
const DAY_MS = 24 * 60 * 60 * 1000

/** The headline of the signal, which the server renders. */
export const SIGNAL_HEADLINE = "Offline"

/** The start of the signal's caption, which says what the map shows. */
export const SignalCaption = Object.freeze({
  scheduledPositions: "Showing scheduled positions",
  noSavedSchedules: "No saved schedules",
  savedSchedulesEnded: "Saved schedules ended"
})

const CAPTION_SEPARATOR = " · "

/** What the page's polite live region says when the connection changes. */
export const AnnouncementText = Object.freeze({offline: "You are offline.", online: "Back online."})

/** Whether a change of the connection is announced. */
export const AnnouncementKind = Object.freeze({none: "none", say: "say"})

/** An age of `ageMs` as a rider reads it, such as "3 h ago"; an age under a minute, or one from a clock ahead, is "just now". */
export function ageText(ageMs) {
  assertCondition(Number.isFinite(ageMs), `an age is a number: ${ageMs}`)

  if (ageMs < MINUTE_MS) {
    return "just now"
  }

  if (ageMs < HOUR_MS) {
    return `${Math.floor(ageMs / MINUTE_MS)} min ago`
  }

  if (ageMs < DAY_MS) {
    return `${Math.floor(ageMs / HOUR_MS)} h ago`
  }

  return `${Math.floor(ageMs / DAY_MS)} d ago`
}

// The instant of the newest build among `dates`, in milliseconds since the
// Unix epoch.
function newestBuildMs(dates) {
  assertCondition(dates.length > 0, "a newest build is of one date or more")
  let newestMs = 0

  for (const date of dates) {
    newestMs = Math.max(newestMs, Date.parse(date.builtAt))
  }

  return newestMs
}

/** The signal's headline and caption at `nowMs` for `savedIndex`, a read of the offline schedules' saved index. */
export function signalMessage({savedIndex, nowMs}) {
  assertCondition(Number.isFinite(nowMs), `the time is a number: ${nowMs}`)

  if (savedIndex.kind === IndexKind.none) {
    return {headline: SIGNAL_HEADLINE, caption: SignalCaption.noSavedSchedules}
  }

  assertCondition(savedIndex.kind === IndexKind.found, `a saved index is found or none: ${savedIndex.kind}`)
  const {index} = savedIndex
  const currentDates = []

  for (const date of index.dates) {
    if (date.validUntilMs > nowMs) {
      currentDates.push(date)
    }
  }

  if (currentDates.length === 0) {
    const savedAge = ageText(nowMs - index.savedAtMs)
    return {headline: SIGNAL_HEADLINE, caption: `${SignalCaption.savedSchedulesEnded}${CAPTION_SEPARATOR}saved ${savedAge}`}
  }

  const builtMs = newestBuildMs(currentDates)
  const builtAge = ageText(nowMs - builtMs)
  return {headline: SIGNAL_HEADLINE, caption: `${SignalCaption.scheduledPositions}${CAPTION_SEPARATOR}updated ${builtAge}`}
}

/** What the live region says when the connection moves from `previous` to `next`: going offline and coming back, and nothing else. */
export function announcementOf({previous, next}) {
  const wasOffline = previous.kind === ConnectionKind.offline
  const isOffline = next.kind === ConnectionKind.offline

  if (wasOffline === isOffline) {
    return {kind: AnnouncementKind.none}
  }

  if (isOffline) {
    return {kind: AnnouncementKind.say, text: AnnouncementText.offline}
  }

  switch (next.kind) {
    case ConnectionKind.live:
      return {kind: AnnouncementKind.say, text: AnnouncementText.online}
    case ConnectionKind.connecting:
      return {kind: AnnouncementKind.none}
    default:
      return unreachable(next.kind, "connection kind")
  }
}
