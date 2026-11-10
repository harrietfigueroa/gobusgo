// Checks the rules of the page's connection state and of the offline
// signal against cases written out by hand: the state a page starts in for
// each browser and render stamp, each state's answer to each event, the
// three thresholds, the signal's lines for each saved index, the age texts,
// and which transitions are announced. Run it with
// `node test/scripts/connection_state_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, ok} from "node:assert/strict"
import {readFileSync} from "node:fs"
import {
  CACHED_COPY_AGE_MS_MAX,
  ConnectionEventKind,
  ConnectionKind,
  JOIN_WAIT_MS,
  OfflineReason,
  RenderStampKind,
  initialConnection,
  isCachedCopy,
  isSameConnection,
  nextConnection,
  renderStampOf,
  waitsForJoin
} from "../../assets/js/connection_rules.js"
import {IndexKind} from "../../assets/js/offline_bundle.js"
import {
  AGE_REFRESH_MS,
  AnnouncementKind,
  AnnouncementText,
  SIGNAL_HEADLINE,
  ageText,
  announcementOf,
  signalMessage
} from "../../assets/js/offline_signal.js"

const SECOND_MS = 1000
const MINUTE_MS = 60 * 1000
const HOUR_MS = 60 * 60 * 1000
const DAY_MS = 24 * 60 * 60 * 1000
const NOW_TEXT = "2026-11-08T18:00:00.000Z"
const NOW_MS = Date.parse(NOW_TEXT)
const JOIN_WAIT_EXPECTED_MS = 10 * 1000
const CACHED_COPY_AGE_EXPECTED_MS = 2 * 60 * 1000
const LAST_MINUTE_MS = 59 * 60 * 1000
// 23 h 59 min, and 3 d 1 h.
const LAST_HOUR_MS = 1439 * 60 * 1000
const THREE_DAYS_AND_AN_HOUR_MS = 73 * 60 * 60 * 1000
const TWO_DAYS_MS = 2 * 24 * 60 * 60 * 1000
const TWENTY_MINUTES_MS = 20 * 60 * 1000
const THREE_HOURS_MS = 3 * 60 * 60 * 1000
const FIVE_HOURS_MS = 5 * 60 * 60 * 1000
const SIX_HOURS_MS = 6 * 60 * 60 * 1000

deepStrictEqual(JOIN_WAIT_MS, JOIN_WAIT_EXPECTED_MS, "a page with no join for 10 s is offline")
deepStrictEqual(CACHED_COPY_AGE_MS_MAX, CACHED_COPY_AGE_EXPECTED_MS, "a page rendered more than 2 minutes ago is a cached copy")
deepStrictEqual(AGE_REFRESH_MS, MINUTE_MS, "the signal's age is written again every minute")

const connecting = {kind: ConnectionKind.connecting}
const live = {kind: ConnectionKind.live}
const browserOffline = {kind: ConnectionKind.offline, reason: OfflineReason.browserOffline}
const serverUnreachable = {kind: ConnectionKind.offline, reason: OfflineReason.serverUnreachable}

// The render stamp, read from the meta element's content.
const stampCases = [
  {name: "an ISO 8601 time", content: NOW_TEXT, expected: {kind: RenderStampKind.stamped, renderedAtMs: NOW_MS}},
  {name: "no content", content: "", expected: {kind: RenderStampKind.unstamped}},
  {name: "a text that is no time", content: "yesterday", expected: {kind: RenderStampKind.unstamped}}
]

for (const {name, content, expected} of stampCases) {
  deepStrictEqual(renderStampOf(content), expected, `the render stamp of ${name}`)
}

function stampedAgo(ageMs) {
  return {kind: RenderStampKind.stamped, renderedAtMs: NOW_MS - ageMs}
}

const unstamped = {kind: RenderStampKind.unstamped}

// A copy is cached once its render is older than the threshold, and a page
// with no stamp is never one.
const cachedCases = [
  {name: "a page rendered now", renderStamp: stampedAgo(0), expected: false},
  {name: "a page rendered exactly 2 minutes ago", renderStamp: stampedAgo(CACHED_COPY_AGE_MS_MAX), expected: false},
  {name: "a page rendered just over 2 minutes ago", renderStamp: stampedAgo(CACHED_COPY_AGE_MS_MAX + 1), expected: true},
  {name: "a page rendered in the browser's future", renderStamp: stampedAgo(-HOUR_MS), expected: false},
  {name: "a page with no stamp", renderStamp: unstamped, expected: false}
]

for (const {name, renderStamp, expected} of cachedCases) {
  deepStrictEqual(isCachedCopy({renderStamp, nowMs: NOW_MS}), expected, `whether ${name} is a cached copy`)
}

// The state a page starts in: offline at once with the browser offline or
// for a cached copy, and otherwise waiting for its join.
const initialCases = [
  {name: "a fresh page in an online browser", isBrowserOnline: true, renderStamp: stampedAgo(SECOND_MS), expected: connecting},
  {name: "a page with no stamp in an online browser", isBrowserOnline: true, renderStamp: unstamped, expected: connecting},
  {name: "a fresh page in an offline browser", isBrowserOnline: false, renderStamp: stampedAgo(SECOND_MS), expected: browserOffline},
  {name: "a cached copy in an online browser", isBrowserOnline: true, renderStamp: stampedAgo(HOUR_MS), expected: serverUnreachable},
  {name: "a cached copy in an offline browser", isBrowserOnline: false, renderStamp: stampedAgo(HOUR_MS), expected: browserOffline}
]

for (const {name, isBrowserOnline, renderStamp, expected} of initialCases) {
  deepStrictEqual(initialConnection({isBrowserOnline, renderStamp, nowMs: NOW_MS}), expected, `the start of ${name}`)
}

const joined = {kind: ConnectionEventKind.joined}
const disconnected = {kind: ConnectionEventKind.disconnected}
// The browser's network comes back to a socket that lost its join, or to
// one that stayed joined through the outage.
const online = {kind: ConnectionEventKind.browserOnline, isJoined: false}
const onlineJoined = {kind: ConnectionEventKind.browserOnline, isJoined: true}
const offline = {kind: ConnectionEventKind.browserOffline}
const joinWaitEnded = {kind: ConnectionEventKind.joinWaitEnded}

// Each state's answer to each event.
const transitionCases = [
  {from: "connecting", connection: connecting, event: joined, expected: live},
  {from: "connecting", connection: connecting, event: disconnected, expected: connecting},
  {from: "connecting", connection: connecting, event: online, expected: connecting},
  {from: "connecting", connection: connecting, event: onlineJoined, expected: connecting},
  {from: "connecting", connection: connecting, event: offline, expected: browserOffline},
  {from: "connecting", connection: connecting, event: joinWaitEnded, expected: serverUnreachable},
  {from: "live", connection: live, event: joined, expected: live},
  {from: "live", connection: live, event: disconnected, expected: connecting},
  {from: "live", connection: live, event: online, expected: live},
  {from: "live", connection: live, event: onlineJoined, expected: live},
  {from: "live", connection: live, event: offline, expected: browserOffline},
  {from: "live", connection: live, event: joinWaitEnded, expected: live},
  {from: "browser offline", connection: browserOffline, event: joined, expected: live},
  {from: "browser offline", connection: browserOffline, event: disconnected, expected: browserOffline},
  {from: "browser offline", connection: browserOffline, event: online, expected: serverUnreachable},
  {from: "browser offline", connection: browserOffline, event: onlineJoined, expected: live},
  {from: "browser offline", connection: browserOffline, event: offline, expected: browserOffline},
  {from: "browser offline", connection: browserOffline, event: joinWaitEnded, expected: browserOffline},
  {from: "server unreachable", connection: serverUnreachable, event: joined, expected: live},
  {from: "server unreachable", connection: serverUnreachable, event: disconnected, expected: serverUnreachable},
  {from: "server unreachable", connection: serverUnreachable, event: online, expected: serverUnreachable},
  {from: "server unreachable", connection: serverUnreachable, event: onlineJoined, expected: live},
  {from: "server unreachable", connection: serverUnreachable, event: offline, expected: browserOffline},
  {from: "server unreachable", connection: serverUnreachable, event: joinWaitEnded, expected: serverUnreachable}
]

for (const {from, connection, event, expected} of transitionCases) {
  deepStrictEqual(nextConnection({connection, event}), expected, `${from} on ${event.kind} ${event.isJoined}`)
}

// Only a page waiting for its join starts the join wait.
const waitCases = [
  {connection: connecting, expected: true},
  {connection: live, expected: false},
  {connection: browserOffline, expected: false},
  {connection: serverUnreachable, expected: false}
]

for (const {connection, expected} of waitCases) {
  deepStrictEqual(waitsForJoin(connection), expected, `whether ${connection.kind} ${connection.reason} waits for a join`)
}

ok(isSameConnection(browserOffline, {kind: ConnectionKind.offline, reason: OfflineReason.browserOffline}), "two offline states with one reason are one")
ok(!isSameConnection(browserOffline, serverUnreachable), "two offline states with two reasons differ")
ok(!isSameConnection(connecting, live), "connecting and live differ")

// Texts of an age.
const ageCases = [
  {ageMs: 0, expected: "just now"},
  {ageMs: MINUTE_MS - 1, expected: "just now"},
  {ageMs: MINUTE_MS, expected: "1 min ago"},
  {ageMs: LAST_MINUTE_MS, expected: "59 min ago"},
  {ageMs: HOUR_MS, expected: "1 h ago"},
  {ageMs: LAST_HOUR_MS, expected: "23 h ago"},
  {ageMs: DAY_MS, expected: "1 d ago"},
  {ageMs: THREE_DAYS_AND_AN_HOUR_MS, expected: "3 d ago"},
  {ageMs: -MINUTE_MS, expected: "just now"}
]

for (const {ageMs, expected} of ageCases) {
  deepStrictEqual(ageText(ageMs), expected, `the text of an age of ${ageMs} ms`)
}

function savedIndex({savedAgoMs, dates}) {
  return {kind: IndexKind.found, index: {savedAtMs: NOW_MS - savedAgoMs, formatVersion: 1, dates, paths: []}}
}

function date({serviceDate, builtAgoMs, validForMs}) {
  return {
    serviceDate,
    builtAt: new Date(NOW_MS - builtAgoMs).toISOString(),
    sourceFetchedAtNewest: new Date(NOW_MS - builtAgoMs).toISOString(),
    validUntilMs: NOW_MS + validForMs
  }
}

// The signal's headline and caption for each saved index.
const signalCases = [
  {
    name: "no saved index",
    savedIndex: {kind: IndexKind.none},
    expected: {headline: "Offline", caption: "No saved schedules"}
  },
  {
    name: "a saved index whose every date has ended",
    savedIndex: savedIndex({
      savedAgoMs: TWO_DAYS_MS,
      dates: [date({serviceDate: "2026-11-06", builtAgoMs: TWO_DAYS_MS, validForMs: -DAY_MS})]
    }),
    expected: {headline: "Offline", caption: "Saved schedules ended · saved 2 d ago"}
  },
  {
    name: "a saved index with a current date, aged by its newest build",
    savedIndex: savedIndex({
      savedAgoMs: TWENTY_MINUTES_MS,
      dates: [
        date({serviceDate: "2026-11-08", builtAgoMs: THREE_HOURS_MS, validForMs: HOUR_MS}),
        date({serviceDate: "2026-11-09", builtAgoMs: FIVE_HOURS_MS, validForMs: DAY_MS})
      ]
    }),
    expected: {headline: "Offline", caption: "Showing scheduled positions · updated 3 h ago"}
  },
  {
    name: "a saved index whose ended date is the newest build",
    savedIndex: savedIndex({
      savedAgoMs: TWENTY_MINUTES_MS,
      dates: [
        date({serviceDate: "2026-11-07", builtAgoMs: HOUR_MS, validForMs: -MINUTE_MS}),
        date({serviceDate: "2026-11-08", builtAgoMs: SIX_HOURS_MS, validForMs: HOUR_MS})
      ]
    }),
    expected: {headline: "Offline", caption: "Showing scheduled positions · updated 6 h ago"}
  }
]

for (const {name, savedIndex: index, expected} of signalCases) {
  deepStrictEqual(signalMessage({savedIndex: index, nowMs: NOW_MS}), expected, `the signal's message for ${name}`)
}

// The server renders the headline the hook's message names, and the hook
// writes only the caption.
const signalMarkup = readFileSync("lib/gobusgo_web/components/connection_signal.ex", "utf8")
ok(signalMarkup.includes(`class="message-headline">${SIGNAL_HEADLINE}</span>`), "the server renders the signal's headline")

const silent = {kind: AnnouncementKind.none}
const sayOffline = {kind: AnnouncementKind.say, text: AnnouncementText.offline}
const sayOnline = {kind: AnnouncementKind.say, text: AnnouncementText.online}

deepStrictEqual(AnnouncementText, {offline: "You are offline.", online: "Back online."}, "the announcements' texts")

// Only going offline and coming back are announced.
const announcementCases = [
  {name: "connecting to live", previous: connecting, next: live, expected: silent},
  {name: "live to connecting", previous: live, next: connecting, expected: silent},
  {name: "connecting to offline", previous: connecting, next: serverUnreachable, expected: sayOffline},
  {name: "live to offline", previous: live, next: browserOffline, expected: sayOffline},
  {name: "offline to another reason", previous: browserOffline, next: serverUnreachable, expected: silent},
  {name: "offline to live", previous: serverUnreachable, next: live, expected: sayOnline}
]

for (const {name, previous, next, expected} of announcementCases) {
  deepStrictEqual(announcementOf({previous, next}), expected, `the announcement of ${name}`)
}

console.log("connection state: every case passed")
