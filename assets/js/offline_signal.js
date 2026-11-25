// What the offline signal says. Everything here is pure: the Save for
// offline use setting, the saved index of the offline schedules, the time,
// and the connection states are given as values, so the signal's message
// and its announcements are functions of them.
//
// The signal's headline says the page is offline. With the setting off its
// caption points to the setting; in a browser that cannot save, the caption
// says so; with the setting on, the caption says what the map shows and how
// old the saved schedules are: by their newest build while a saved date is
// current, and by when they were saved once every date has ended. The
// signal opens the setting, so its accessible name holds its visible text
// and says where it goes.

import {assertCondition, unreachable} from "#core/assert.js"
import {ConnectionKind} from "./connection_rules.js"
import {IndexKind} from "#core/offline_bundle.js"

/** How often an offline page writes the signal's age again. */
export const AGE_REFRESH_MS = 60 * 1000

const MINUTE_MS = 60 * 1000
const HOUR_MS = 60 * 60 * 1000
const DAY_MS = 24 * 60 * 60 * 1000

/** The headline of the signal, which the server renders. */
export const SIGNAL_HEADLINE = "Offline"

/** The start of the signal's caption. */
export const SignalCaption = Object.freeze({
  offlineUseOff: "Turn on offline use in Settings",
  offlineUseUnsupported: "This browser can't save for offline use",
  scheduledPositions: "Showing scheduled positions",
  noSavedSchedules: "No saved schedules",
  savedSchedulesEnded: "Saved schedules ended"
})

const CAPTION_SEPARATOR = " · "

/** The end of the signal's accessible name while its caption names no destination. */
export const SIGNAL_DESTINATION = "Open offline use in Settings"

/** The state of the Save for offline use setting; `on` carries a read of the saved index, and `unsupported` is a browser that cannot save. */
export const OfflineUseKind = Object.freeze({off: "off", on: "on", unsupported: "unsupported"})

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

// The caption at `nowMs` for `savedIndex`, a read of the offline schedules'
// saved index.
function savedCaption({savedIndex, nowMs}) {
  if (savedIndex.kind === IndexKind.none) {
    return SignalCaption.noSavedSchedules
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
    return `${SignalCaption.savedSchedulesEnded}${CAPTION_SEPARATOR}saved ${savedAge}`
  }

  const builtMs = newestBuildMs(currentDates)
  const builtAge = ageText(nowMs - builtMs)
  return `${SignalCaption.scheduledPositions}${CAPTION_SEPARATOR}updated ${builtAge}`
}

/**
 * The signal's headline, caption, and accessible name at `nowMs` for
 * `offlineUse`, the setting's state: `{kind: OfflineUseKind.off}`,
 * `{kind: OfflineUseKind.unsupported}`, or
 * `{kind: OfflineUseKind.on, savedIndex}` with a read of the offline
 * schedules' saved index.
 */
export function signalMessage({offlineUse, nowMs}) {
  assertCondition(Number.isFinite(nowMs), `the time is a number: ${nowMs}`)

  switch (offlineUse.kind) {
    case OfflineUseKind.off: {
      const caption = SignalCaption.offlineUseOff
      return {headline: SIGNAL_HEADLINE, caption, label: `${SIGNAL_HEADLINE}. ${caption}.`}
    }
    case OfflineUseKind.unsupported: {
      const caption = SignalCaption.offlineUseUnsupported
      const label = `${SIGNAL_HEADLINE}. ${caption}. ${SIGNAL_DESTINATION}.`
      return {headline: SIGNAL_HEADLINE, caption, label}
    }
    case OfflineUseKind.on: {
      const caption = savedCaption({savedIndex: offlineUse.savedIndex, nowMs})
      const label = `${SIGNAL_HEADLINE}. ${caption}. ${SIGNAL_DESTINATION}.`
      return {headline: SIGNAL_HEADLINE, caption, label}
    }
    default:
      return unreachable(offlineUse.kind, "offline use kind")
  }
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
