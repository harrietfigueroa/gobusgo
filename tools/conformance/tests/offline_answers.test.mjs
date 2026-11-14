// Checks what the page answers for itself while it is offline, as pure
// functions of saved snapshot tables written out by hand: which answer each
// event the hooks push gets, a stop's position, the names of a trip's stops
// and routes with and without a names file, the routes of a trip's filter
// and the summary line it shows, the order the saved snapshots are read in,
// and the closes kept for the server.

import {describe, expect, test} from "vitest"
import {IMPLEMENTATIONS} from "../implementations.mjs"

const NAME_COUNT_MAX = 3
const ROUTE_COUNT_MAX = 2
const HOUR_MS = 60 * 60 * 1000
const THREE_HOURS_MS = 3 * 60 * 60 * 1000
const DAY_MS = 24 * 60 * 60 * 1000
const DAY_START_MS = Date.parse("2026-11-08T08:00:00.000Z")
const NEXT_DAY_START_MS = DAY_START_MS + DAY_MS
// The last departure of a date is past midnight, 26 hours after its start.
const LAST_DEPARTURE_SECONDS = 26 * 60 * 60
const UNKNOWN_MICRODEGREES = -2147483648
const PIKE_LAT_MICRODEGREES = 47608000
const PIKE_LON_MICRODEGREES = -122335000
const SECOND_STOP_LAT_MICRODEGREES = 47620500
const SECOND_STOP_LON_MICRODEGREES = -122349250
const LATER_STOP_LAT_MICRODEGREES = 47500000
const LATER_STOP_LON_MICRODEGREES = -122300000

// The stops file's identifiers by index, as the page keys them.
function indexesOf(stopIds) {
  const indexes = new Map()

  for (const [index, stopId] of stopIds.entries()) {
    indexes.set(stopId, index)
  }

  return indexes
}

function entry({serviceDate, serviceDayStartMs}) {
  return {serviceDate, serviceDayStartMs, connectionChunks: [{departureSMin: 0, departureSMax: LAST_DEPARTURE_SECONDS}]}
}

const manifest = {
  snapshots: [entry({serviceDate: "2026-11-08", serviceDayStartMs: DAY_START_MS}), entry({serviceDate: "2026-11-09", serviceDayStartMs: NEXT_DAY_START_MS})]
}

function serviceDateOf(chosen) {
  return chosen.serviceDate
}

function stopIdOf(_value, index) {
  return `stop_${index}`
}

describe.each(IMPLEMENTATIONS)("offline answers ($name)", ({AssertionError, offlineAnswers, tripPlan}) => {
  const {ROUTE_COLOR_DEFAULT} = tripPlan
  const {
    DEFERRED_CLOSE_COUNT_MAX,
    FILTER_RESTORE_REPLY,
    LocalAnswerKind,
    PageEventName,
    REFUSED_REPLY,
    TableKind,
    TripFilterKind,
    localAnswerOf,
    namesReply,
    positionReply,
    snapshotOrder,
    tripFilterOf,
    tripSummaryText,
    withClose,
    withoutClose
  } = offlineAnswers

  function missing() {
    return {kind: TableKind.missing}
  }

  function found(table) {
    return {kind: TableKind.found, table}
  }

  function namesOf({stopNames, stopCodes, routes}) {
    return found({stopNames, stopCodes, tripHeadsigns: [], routes, agencyNames: {}})
  }

  // Stops 1_10 and 1_20 with known positions and 1_30 with none; a names
  // file for all three and for routes 100479 and 100512, the second with no
  // short name and no color.
  const today = {
    serviceDate: "2026-11-08",
    stopIndexes: indexesOf(["1_10", "1_20", "1_30"]),
    positions: found({
      latMicrodegrees: Int32Array.from([PIKE_LAT_MICRODEGREES, SECOND_STOP_LAT_MICRODEGREES, UNKNOWN_MICRODEGREES]),
      lonMicrodegrees: Int32Array.from([PIKE_LON_MICRODEGREES, SECOND_STOP_LON_MICRODEGREES, UNKNOWN_MICRODEGREES])
    }),
    names: namesOf({
      stopNames: ["3rd Ave & Pike St", null, "Westlake Station"],
      stopCodes: ["10", "20", null],
      routes: {
        "1_100479": {shortName: "E", longName: "E Line", color: "B3282D", agencyId: "1"},
        "1_100512": {shortName: null, longName: "Link light rail", color: null, agencyId: "40"}
      }
    })
  }

  // A later date that holds 1_40 alone, with no names file.
  const tomorrow = {
    serviceDate: "2026-11-09",
    stopIndexes: indexesOf(["1_40"]),
    positions: found({latMicrodegrees: Int32Array.of(LATER_STOP_LAT_MICRODEGREES), lonMicrodegrees: Int32Array.of(LATER_STOP_LON_MICRODEGREES)}),
    names: missing()
  }

  const answerCases = [
    {name: "a stop's position is read from the saved positions", event: PageEventName.stopPosition, kind: LocalAnswerKind.position},
    {name: "a trip's names are read from the saved names file", event: PageEventName.tripNames, kind: LocalAnswerKind.names},
    {name: "a trip's filter is applied in the page", event: PageEventName.tripFilter, kind: LocalAnswerKind.tripFilter},
    {name: "clearing a trip ends its filter in the page", event: PageEventName.tripClear, kind: LocalAnswerKind.tripClear},
    {name: "the stored filter is kept, read-only", event: PageEventName.filterRestore, kind: LocalAnswerKind.filterRestore},
    {name: "a stop opened again is no longer closed for the server", event: PageEventName.arrivalsOpen, kind: LocalAnswerKind.cancelClose},
    {name: "a closed stop is closed for the server once live", event: PageEventName.arrivalsClose, kind: LocalAnswerKind.deferClose},
    {name: "the vehicle markers come from the schedule while offline", event: PageEventName.markersReady, kind: LocalAnswerKind.scheduledMarkers},
    {name: "scooters are not shown while offline", event: PageEventName.sharedVehiclesShow, kind: LocalAnswerKind.unanswered},
    {name: "scooters are not hidden while offline", event: PageEventName.sharedVehiclesHide, kind: LocalAnswerKind.unanswered}
  ]

  test.each(answerCases)("answer: $name", ({event, kind}) => {
    expect(localAnswerOf(event)).toBe(kind)
  })

  test("every event a hook pushes has a case", () => {
    expect(Object.keys(PageEventName).length).toBe(answerCases.length)
  })

  test("an event no hook pushes is a programmer error", () => {
    expect(() => localAnswerOf("vehicle-filter:query")).toThrow(AssertionError)
  })

  test("the stored filter is accepted, so the browser keeps it", () => {
    expect(FILTER_RESTORE_REPLY).toStrictEqual({accepted: true})
  })

  const positionCases = [
    {name: "a stop's position in degrees", payload: {stop_id: "1_10"}, expected: () => ({lat: 47.608, lon: -122.335})},
    {name: "microdegrees convert exactly", payload: {stop_id: "1_20"}, expected: () => ({lat: 47.6205, lon: -122.34925})},
    {name: "a stop of the later date alone is found there", payload: {stop_id: "1_40"}, expected: () => ({lat: 47.5, lon: -122.3})},
    {name: "a stop with no known position is refused", payload: {stop_id: "1_30"}, expected: () => REFUSED_REPLY},
    {name: "a stop no snapshot holds is refused", payload: {stop_id: "1_99"}, expected: () => REFUSED_REPLY},
    {name: "a request that names no stop is refused", payload: {}, expected: () => REFUSED_REPLY},
    {name: "a stop identifier that is not text is refused", payload: {stop_id: 10}, expected: () => REFUSED_REPLY}
  ]

  test.each(positionCases)("position: $name", ({payload, expected}) => {
    expect(positionReply({snapshots: [today, tomorrow], payload})).toStrictEqual(expected())
  })

  test("a snapshot with no saved positions knows no position", () => {
    const unpositioned = {...today, positions: missing()}
    expect(positionReply({snapshots: [unpositioned], payload: {stop_id: "1_10"}})).toStrictEqual(REFUSED_REPLY)
  })

  test("with nothing saved every stop is refused", () => {
    expect(positionReply({snapshots: [], payload: {stop_id: "1_10"}})).toStrictEqual(REFUSED_REPLY)
  })

  test("names come from the names file; a stop or route it lacks is left to its identifier", () => {
    const payload = {stop_ids: ["1_10", "1_20", "1_40"], route_ids: ["1_100479", "1_100512", "1_999"]}
    expect(namesReply({snapshots: [today, tomorrow], payload, countMax: NAME_COUNT_MAX})).toStrictEqual({
      stops: {
        "1_10": {name: "3rd Ave & Pike St", code: "10"},
        "1_20": {name: null, code: "20"}
      },
      routes: {
        "1_100479": {name: "E", color: "#B3282D"},
        "1_100512": {name: "Link light rail", color: ROUTE_COLOR_DEFAULT}
      }
    })
  })

  test("with no names file every stop and route keeps its identifier", () => {
    const payload = {stop_ids: ["1_40"], route_ids: ["1_100479"]}
    expect(namesReply({snapshots: [tomorrow], payload, countMax: NAME_COUNT_MAX})).toStrictEqual({stops: {}, routes: {}})
  })

  const refusedNameCases = [
    {name: "a request with no routes", payload: {stop_ids: ["1_10"]}},
    {name: "stops that are not a list", payload: {stop_ids: "1_10", route_ids: []}},
    {name: "a stop identifier that is not text", payload: {stop_ids: ["1_10", true], route_ids: []}},
    {name: "more stops than the bound", payload: {stop_ids: ["a", "b", "c", "d"], route_ids: []}},
    {name: "more routes than the bound", payload: {stop_ids: [], route_ids: ["a", "b", "c", "d"]}}
  ]

  test.each(refusedNameCases)("names refused: $name", ({payload}) => {
    expect(namesReply({snapshots: [today], payload, countMax: NAME_COUNT_MAX})).toStrictEqual(REFUSED_REPLY)
  })

  const tripFilterCases = [
    {name: "a trip's routes are its filter", payload: {route_ids: ["1_100479", "1_100512"]}, expected: () => ({kind: TripFilterKind.accepted, routeIds: ["1_100479", "1_100512"]})},
    {name: "a route ridden twice is kept once", payload: {route_ids: ["1_100479", "1_100479"]}, expected: () => ({kind: TripFilterKind.accepted, routeIds: ["1_100479"]})},
    {name: "a trip with no route is refused", payload: {route_ids: []}, expected: () => ({kind: TripFilterKind.refused})},
    {name: "more routes than the bound are refused", payload: {route_ids: ["a", "b", "c"]}, expected: () => ({kind: TripFilterKind.refused})},
    {name: "a route identifier that is not text is refused", payload: {route_ids: [true]}, expected: () => ({kind: TripFilterKind.refused})},
    {name: "a request that names no routes is refused", payload: {}, expected: () => ({kind: TripFilterKind.refused})}
  ]

  test.each(tripFilterCases)("trip filter: $name", ({payload, expected}) => {
    expect(tripFilterOf({payload, countMax: ROUTE_COUNT_MAX})).toStrictEqual(expected())
  })

  test("the summary names the trip's routes in riding order, by identifier where the names file lacks one", () => {
    const routeIds = ["1_100479", "1_100512", "1_999"]
    expect(tripSummaryText({snapshots: [today], routeIds})).toBe("Showing the trip's routes: E, Link light rail, 1_999")
  })

  test("with no names file the summary names identifiers", () => {
    expect(tripSummaryText({snapshots: [tomorrow], routeIds: ["1_100479"]})).toBe("Showing the trip's routes: 1_100479")
  })

  const orderCases = [
    {name: "the date running now is read first", nowMs: DAY_START_MS + HOUR_MS, expected: ["2026-11-08", "2026-11-09"]},
    {name: "once the next date runs it is read first", nowMs: NEXT_DAY_START_MS + THREE_HOURS_MS, expected: ["2026-11-09", "2026-11-08"]},
    {name: "before any date runs the manifest's order stands", nowMs: DAY_START_MS - HOUR_MS, expected: ["2026-11-08", "2026-11-09"]}
  ]

  test.each(orderCases)("order: $name", ({nowMs, expected}) => {
    const entries = snapshotOrder({manifest, nowMs})
    const serviceDates = Array.from(entries, serviceDateOf)
    expect(serviceDates).toStrictEqual(expected)
  })

  test("a close is kept", () => {
    expect(withClose({closes: [], stopId: "1_10"})).toStrictEqual(["1_10"])
  })

  test("a stop is closed once", () => {
    expect(withClose({closes: ["1_10"], stopId: "1_10"})).toStrictEqual(["1_10"])
  })

  test("a stop opened again is not closed", () => {
    expect(withoutClose({closes: ["1_10", "1_20"], stopId: "1_10"})).toStrictEqual(["1_20"])
  })

  test("opening a stop that was not closed changes nothing", () => {
    expect(withoutClose({closes: ["1_20"], stopId: "1_10"})).toStrictEqual(["1_20"])
  })

  test("the closes kept are bounded, the oldest dropped first", () => {
    const full = Array.from({length: DEFERRED_CLOSE_COUNT_MAX}, stopIdOf)
    const overfull = withClose({closes: full, stopId: "stop_new"})
    expect(overfull.length).toBe(DEFERRED_CLOSE_COUNT_MAX)
    expect([overfull[0], overfull[overfull.length - 1]]).toStrictEqual(["stop_1", "stop_new"])
  })
})
