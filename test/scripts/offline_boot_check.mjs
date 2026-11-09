// Checks the rules of the vehicle page's cold start with no network against
// cases written out by hand: the host's phases and the event that moves
// each, which hooks it mounts, the filter it reads from the address and
// from the browser's store, which of the two applies, the routes that
// filter keeps and the summary line it reads as with and without the saved
// names, and the state a hook hands over, taken once. Run it with
// `node test/scripts/offline_boot_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {HANDOFF_COUNT_MAX, HandoffKind, NO_HANDOFF, keepHandoffState, takeHandoffState} from "../../assets/js/hook_handoff.js"
import {TableKind} from "../../assets/js/offline_answers.js"
import {
  BootEventKind,
  BootPhase,
  FILTER_VALUE_BYTES_MAX,
  FILTER_VALUE_COUNT_MAX,
  KeptRoutesKind,
  ReadFilterKind,
  SummaryKind,
  addressFilterOf,
  bootFilterOf,
  isHostMounted,
  keptRoutesOf,
  nextBootPhase,
  storedFilterOf,
  summaryOf
} from "../../assets/js/offline_boot_rules.js"

const NON_TEXT_VALUE = 9
const SEATTLE_LONGITUDE = -122.33
const SEATTLE_LATITUDE = 47.6
const CAMERA_ZOOM = 15
const NONE = {kind: ReadFilterKind.none}
const REFUSED = {kind: ReadFilterKind.refused}

function indexText(_value, index) {
  return String(index)
}

function found(filter) {
  return {kind: ReadFilterKind.found, filter}
}

const phaseCases = [
  {name: "an offline page before any join prepares", phase: BootPhase.waiting, event: BootEventKind.offline, next: BootPhase.preparing},
  {name: "a page that joins before it is offline never mounts", phase: BootPhase.waiting, event: BootEventKind.joinPatch, next: BootPhase.handedOff},
  {name: "prepared overrides mount the hooks", phase: BootPhase.preparing, event: BootEventKind.prepared, next: BootPhase.mounted},
  {name: "a join while preparing mounts nothing", phase: BootPhase.preparing, event: BootEventKind.joinPatch, next: BootPhase.handedOff},
  {name: "a page offline again while preparing keeps preparing", phase: BootPhase.preparing, event: BootEventKind.offline, next: BootPhase.preparing},
  {name: "the first join hands the mounted hooks off", phase: BootPhase.mounted, event: BootEventKind.joinPatch, next: BootPhase.handedOff},
  {name: "a mounted host stays mounted while offline", phase: BootPhase.mounted, event: BootEventKind.offline, next: BootPhase.mounted},
  {name: "a handed-off host ignores a later patch", phase: BootPhase.handedOff, event: BootEventKind.joinPatch, next: BootPhase.handedOff},
  {name: "a handed-off host ignores going offline again", phase: BootPhase.handedOff, event: BootEventKind.offline, next: BootPhase.handedOff},
  {name: "a preparation that ends after the handoff mounts nothing", phase: BootPhase.handedOff, event: BootEventKind.prepared, next: BootPhase.handedOff}
]

for (const {name, phase, event, next} of phaseCases) {
  deepStrictEqual(nextBootPhase({phase, event}), next, name)
}

throws(() => nextBootPhase({phase: BootPhase.waiting, event: BootEventKind.prepared}), "a preparation that never started is a programmer error")

const mountCases = [
  {name: "the hook that reports the join is LiveView's alone", hookName: "ConnectionState", mounted: false},
  {name: "the basemap", hookName: "Basemap", mounted: true},
  {name: "the offline signal", hookName: "ConnectionSignal", mounted: true},
  {name: "the panel sheet", hookName: "PanelSheet", mounted: true}
]

for (const {name, hookName, mounted} of mountCases) {
  deepStrictEqual(isHostMounted(hookName), mounted, name)
}

const longValue = "x".repeat(FILTER_VALUE_BYTES_MAX + 1)
const manyValueTexts = Array.from({length: FILTER_VALUE_COUNT_MAX + 1}, indexText)
const manyValues = manyValueTexts.join(",")

const addressCases = [
  {name: "no query", search: "", read: NONE},
  {name: "a query with no filter field", search: "?zoom=12", read: NONE},
  {name: "one route", search: "?route=1_100479", read: found({route: ["1_100479"]})},
  {name: "agencies and routes, sorted and once each", search: "?route=40_2,1_9,40_2&agency=40,1", read: found({agency: ["1", "40"], route: ["1_9", "40_2"]})},
  {name: "empty values are dropped", search: "?agency=1,,", read: found({agency: ["1"]})},
  {name: "a field left with no value is dropped", search: "?agency=&route=1_9", read: found({route: ["1_9"]})},
  {name: "only empty values hold no filter", search: "?agency=", read: NONE},
  {name: "a value over the byte bound is refused", search: `?route=${longValue}`, read: REFUSED},
  {name: "too many values are refused", search: `?agency=${manyValues}`, read: REFUSED},
  {name: "a field given twice reads its last", search: "?agency=1&agency=40", read: found({agency: ["40"]})}
]

for (const {name, search, read} of addressCases) {
  deepStrictEqual(addressFilterOf(search), read, name)
}

const storedCases = [
  {name: "nothing stored", stored: {kind: "none"}, read: NONE},
  {name: "a stored route", stored: {kind: "found", filter: {route: ["1_9"]}}, read: found({route: ["1_9"]})},
  {name: "a stored filter of no field", stored: {kind: "found", filter: {}}, read: NONE},
  {name: "a stored field this page has not", stored: {kind: "found", filter: {stop: ["1_5"]}}, read: REFUSED},
  {name: "a stored value that is no text", stored: {kind: "found", filter: {route: [NON_TEXT_VALUE]}}, read: REFUSED},
  {name: "a stored field that is no list", stored: {kind: "found", filter: {route: "1_9"}}, read: REFUSED},
  {name: "a stored filter that is no object", stored: {kind: "found", filter: ["1_9"]}, read: REFUSED}
]

for (const {name, stored, read} of storedCases) {
  deepStrictEqual(storedFilterOf(stored), read, name)
}

const addressRoute = found({route: ["1_9"]})
const storedAgency = found({agency: ["40"]})

const bootFilterCases = [
  {name: "the address's filter wins", address: addressRoute, stored: storedAgency, read: addressRoute},
  {name: "no filter in the address: the stored one", address: NONE, stored: storedAgency, read: storedAgency},
  {name: "a refused address: the stored one", address: REFUSED, stored: storedAgency, read: storedAgency},
  {name: "neither: no filter", address: NONE, stored: NONE, read: NONE},
  {name: "a refused stored filter holds none", address: NONE, stored: REFUSED, read: NONE}
]

for (const {name, address, stored, read} of bootFilterCases) {
  deepStrictEqual(bootFilterOf({address, stored}), read, name)
}

const names = {
  kind: TableKind.found,
  table: {
    routes: {
      "1_9": {shortName: "9", longName: "Broadway", color: "aa0000", agencyId: "1"},
      "1_8": {shortName: null, longName: "Capitol Hill", color: null, agencyId: "1"},
      "40_2": {shortName: "2 Line", longName: null, color: "0055aa", agencyId: "40"},
      "40_7": {shortName: null, longName: null, color: null, agencyId: "40"}
    },
    agencyNames: {"1": "King County Metro", "40": "Sound Transit"}
  }
}

const named = [{names}]
const unnamed = [{names: {kind: TableKind.missing}}]
const EVERY = {kind: KeptRoutesKind.every}

function keptRoutes(routeIds) {
  return {kind: KeptRoutesKind.routes, routeIds}
}

const keptCases = [
  {name: "no filter keeps every route", filter: NONE, snapshots: named, kept: EVERY},
  {name: "routes keep those routes", filter: found({route: ["1_9", "40_2"]}), snapshots: named, kept: keptRoutes(["1_9", "40_2"])},
  {name: "routes keep those routes with no names saved", filter: found({route: ["1_9"]}), snapshots: unnamed, kept: keptRoutes(["1_9"])},
  {name: "an agency keeps its saved routes", filter: found({agency: ["40"]}), snapshots: named, kept: keptRoutes(["40_2", "40_7"])},
  {name: "an agency with no names saved keeps every route", filter: found({agency: ["40"]}), snapshots: unnamed, kept: EVERY},
  {name: "an agency no saved route names keeps none", filter: found({agency: ["99"]}), snapshots: named, kept: keptRoutes([])},
  {name: "an agency and routes keep the routes of the agency", filter: found({agency: ["1"], route: ["1_9", "40_2"]}), snapshots: named, kept: keptRoutes(["1_9"])},
  {name: "a route no names file holds is kept", filter: found({agency: ["1"], route: ["1_404"]}), snapshots: named, kept: keptRoutes(["1_404"])}
]

for (const {name, filter, snapshots, kept} of keptCases) {
  deepStrictEqual(keptRoutesOf({filter, snapshots}), kept, name)
}

const summaryCases = [
  {name: "no filter reads as rendered", filter: NONE, snapshots: named, summary: {kind: SummaryKind.rendered}},
  {
    name: "agencies and routes by their saved names",
    filter: found({agency: ["1", "40"], route: ["1_8", "1_9", "40_7"]}),
    snapshots: named,
    summary: {kind: SummaryKind.named, agencyNames: ["King County Metro", "Sound Transit"], routeNames: ["Capitol Hill", "9", "40_7"]}
  },
  {
    name: "identifiers with no names saved",
    filter: found({agency: ["1"], route: ["1_9"]}),
    snapshots: unnamed,
    summary: {kind: SummaryKind.named, agencyNames: ["1"], routeNames: ["1_9"]}
  }
]

for (const {name, filter, snapshots, summary} of summaryCases) {
  deepStrictEqual(summaryOf({filter, snapshots}), summary, name)
}

const camera = {center: [SEATTLE_LONGITUDE, SEATTLE_LATITUDE], zoom: CAMERA_ZOOM, bearing: 0, pitch: 0}
keepHandoffState({elementId: "vehicle-map", state: camera})
deepStrictEqual(takeHandoffState("vehicle-map"), {kind: HandoffKind.found, state: camera}, "a kept state is handed to the next hook of its element")
deepStrictEqual(takeHandoffState("vehicle-map"), NO_HANDOFF, "a handed-over state is taken once")
deepStrictEqual(takeHandoffState("trip-planner"), NO_HANDOFF, "an element nothing was kept for")

for (let index = 0; index < HANDOFF_COUNT_MAX; index += 1) {
  keepHandoffState({elementId: `hook-${index}`, state: index})
}

throws(() => keepHandoffState({elementId: "one-too-many", state: 0}), "more states than a page has hooks are a programmer error")

console.log("offline boot check passed")
