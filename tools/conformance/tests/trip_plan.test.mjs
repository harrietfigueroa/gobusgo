// Checks what the Trip tab decides as pure functions of journeys written
// out by hand in the router's shape: the journey list's order and texts,
// the "Tomorrow" label of a journey that leaves on the next day, whether two
// ends make a query, the time a query leaves at or arrives by and its
// window line, the names the page is asked for, the routes of a trip's
// filter, and what the map draws of a journey.

import {describe, expect, test} from "vitest"
import {IMPLEMENTATIONS} from "../implementations.mjs"

const TIME_ZONE = "America/Los_Angeles"
// 2026-11-08 and 2026-11-09 at midnight in Seattle, eight hours after
// midnight UTC.
const TODAY_START_MS = 1794124800000
const DAY_MS = 24 * 60 * 60 * 1000
const WEEK_MS = 7 * 24 * 60 * 60 * 1000
const HOUR_MS = 60 * 60 * 1000
const HOUR_SECONDS = 60 * 60
const MINUTE_SECONDS = 60
const TOMORROW_START_MS = TODAY_START_MS + DAY_MS
const serviceDayStartsMs = {"2026-11-08": TODAY_START_MS, "2026-11-09": TOMORROW_START_MS}
const SECOND_MS = 1000
const NOW_MS = TODAY_START_MS + seconds("08:38") * SECOND_MS
const LATE_NOW_MS = TODAY_START_MS + seconds("23:30") * SECOND_MS
const NINE_TOMORROW_MS = TOMORROW_START_MS + seconds("09:00") * SECOND_MS
const HALF_EIGHT_MS = TODAY_START_MS + seconds("08:30") * SECOND_MS
// 2026-11-01 at midnight in Seattle, still daylight saving time, seven
// hours after midnight UTC; standard time starts at 02:00 that night.
const NOVEMBER_1_START_MS = TODAY_START_MS - WEEK_MS - HOUR_MS
const OCTOBER_31_AFTERNOON_MS = NOVEMBER_1_START_MS - seconds("10:00") * SECOND_MS
const LAST_DEPARTURE_S = seconds("26:00")
const ROUTE_COUNT_MAX = 6
const ROUTE_COUNT_MAX_ONE = 1
const NAME_COUNT_MAX = 10
const NAME_COUNT_MAX_TWO = 2
const FINAL_STEP_COUNT = 2

// The stops' positions, written as the router hands them over, in degrees.
const PIKE = {lat: 47.61, lon: -122.34}
const PASSED = {lat: 47.6, lon: -122.33}
const CHERRY = {lat: 47.6, lon: -122.33}
const JACKSON = {lat: 47.59, lon: -122.33}
const OTHELLO = {lat: 47.54, lon: -122.28}
const RIDER = {lat: 47.612, lon: -122.341}
const MARKET = {lat: 47.6094, lon: -122.3422}

const names = {
  stops: {
    "1_431": {name: "3rd Ave & Pike St", code: "431"},
    "1_1121": {name: "3rd Ave & Cherry St", code: null},
    "1_1500": {name: "4th Ave S & Jackson St", code: null},
    "1_11920": {name: "Rainier Ave S & S Othello St", code: null}
  },
  routes: {"1_102576": {name: "E", color: "#1D4ED8"}, "1_100210": {name: "36", color: "#EA580C"}}
}

function lonLat({lat, lon}) {
  return [lon, lat]
}

function seconds(clock) {
  const [hours, minutes] = clock.split(":")
  return Number(hours) * HOUR_SECONDS + Number(minutes) * MINUTE_SECONDS
}

function journeyOf(row) {
  return row.journey
}

function kindOf(feature) {
  return feature.properties.kind
}

function featureCount(collection) {
  return collection.features.length
}

function dayEntry({serviceDate, serviceDayStartMs}) {
  return {serviceDate, serviceDayStartMs, connectionChunks: [{departureSMin: 0, departureSMax: LAST_DEPARTURE_S}]}
}

const twoDays = {
  formatVersion: 2,
  snapshots: [dayEntry({serviceDate: "2026-11-08", serviceDayStartMs: TODAY_START_MS}), dayEntry({serviceDate: "2026-11-09", serviceDayStartMs: TOMORROW_START_MS})]
}
const todayOnly = {formatVersion: 2, snapshots: [dayEntry({serviceDate: "2026-11-08", serviceDayStartMs: TODAY_START_MS})]}

describe.each(IMPLEMENTATIONS)("trip plan ($name)", ({AssertionError, pointJourneys, routingEngine, routingJourneys, tripPlan}) => {
  const {LegKind} = routingEngine
  const {FailureReason, JourneysKind} = routingJourneys
  const {LEG_KIND_TO_POINT} = pointJourneys
  const {
    BoundsKind,
    ClockKind,
    EndKind,
    FeatureKind,
    LOCATION_END,
    NO_END,
    QueryKind,
    ROUTE_COLOR_DEFAULT,
    DayChoice,
    PlannedKind,
    StateKind,
    TimeMode,
    defaultClock,
    failureState,
    journeyFeatures,
    journeyRows,
    journeysAnnouncement,
    nameRequest,
    queryOf,
    pickingMessage,
    plannedTime,
    pointEnd,
    stateMessage,
    stopEnd,
    swappedEnds,
    tripRouteIds,
    wallClockMs,
    windowText
  } = tripPlan

  function ride({routeId, from, departs, to, arrives, passing = []}) {
    return {kind: LegKind.ride, tripId: `trip-${routeId}`, routeId, serviceDayOffset: 0, fromStopId: from, departureS: seconds(departs), toStopId: to, arrivalS: seconds(arrives), stopIds: [from, ...passing, to]}
  }

  function walk({from, to, durationS}) {
    return {kind: LegKind.walk, fromStopId: from, toStopId: to, durationS}
  }

  // The earliest journey changes once, from E to 36 after a three-minute
  // walk; a later one rides 7 alone.
  const earliest = {
    serviceDate: "2026-11-08",
    arrivalS: seconds("09:02"),
    changes: 1,
    isEarliest: true,
    legs: [
      ride({routeId: "1_102576", from: "1_431", departs: "08:42", to: "1_1121", arrives: "08:51", passing: ["1_440"]}),
      walk({from: "1_1121", to: "1_1500", durationS: 170}),
      ride({routeId: "1_100210", from: "1_1500", departs: "08:56", to: "1_11920", arrives: "09:02"})
    ],
    stopPositions: {"1_431": PIKE, "1_440": PASSED, "1_1121": CHERRY, "1_1500": JACKSON, "1_11920": OTHELLO}
  }

  const direct = {
    serviceDate: "2026-11-08",
    arrivalS: seconds("09:14"),
    changes: 0,
    isEarliest: false,
    legs: [ride({routeId: "1_100275", from: "1_431", departs: "08:46", to: "1_11920", arrives: "09:14"})],
    stopPositions: {"1_431": PIKE, "1_11920": OTHELLO}
  }

  const tomorrow = {
    ...direct,
    serviceDate: "2026-11-09",
    isEarliest: true,
    arrivalS: seconds("05:40"),
    legs: [ride({routeId: "1_100275", from: "1_431", departs: "05:12", to: "1_11920", arrives: "05:40"})]
  }

  const pastMidnight = {
    ...tomorrow,
    serviceDate: "2026-11-08",
    arrivalS: seconds("24:30"),
    legs: [ride({routeId: "1_100275", from: "1_431", departs: "23:50", to: "1_11920", arrives: "24:30"})]
  }

  const latest = {...direct, isEarliest: undefined, isLatest: true, departureS: seconds("08:46")}
  const sooner = {...earliest, isEarliest: undefined, isLatest: false, departureS: seconds("08:42")}

  function rowsOf({journeys, nowMs}) {
    return journeyRows({journeys, nowMs, serviceDayStartsMs, names, timeZone: TIME_ZONE})
  }

  // The list: fewest changes first, whatever order the router gives.
  test("the order: fewest changes first", () => {
    const rows = rowsOf({journeys: [earliest, direct], nowMs: NOW_MS})
    const ordered = Array.from(rows, journeyOf)
    expect(ordered).toStrictEqual([direct, earliest])
  })

  test("the rows' times, badges, and changes", () => {
    const rows = rowsOf({journeys: [earliest, direct], nowMs: NOW_MS})
    expect(rows[1].timesText).toBe("8:42 am → 9:02 am")
    expect(rows[1].badgeText).toBe("Earliest · 20 min")
    expect(rows[0].badgeText).toBe("28 min")
    expect(rows[1].changesText).toBe("1 change")
    expect(rows[0].changesText).toBe("No change")
  })

  test("the earliest's summary", () => {
    const rows = rowsOf({journeys: [earliest, direct], nowMs: NOW_MS})
    expect(rows[1].summary).toStrictEqual([
      {kind: LegKind.ride, chip: {name: "E", color: "#1D4ED8"}},
      {kind: LegKind.walk, text: "walk 3 min"},
      {kind: LegKind.ride, chip: {name: "36", color: "#EA580C"}}
    ])
  })

  test("the earliest's steps", () => {
    const rows = rowsOf({journeys: [earliest, direct], nowMs: NOW_MS})
    expect(rows[1].steps).toStrictEqual([
      "8:42 am board E at 3rd Ave & Pike St",
      "8:51 am get off at 3rd Ave & Cherry St",
      "walk 3 min to 4th Ave S & Jackson St",
      "8:56 am board 36 at 4th Ave S & Jackson St",
      "9:02 am arrive at Rainier Ave S & S Othello St"
    ])
  })

  // A route and a stop the page has not named read as their identifiers.
  test("an unnamed route and stop read as their identifiers", () => {
    const rows = rowsOf({journeys: [earliest, direct], nowMs: NOW_MS})
    expect(rows[0].summary).toStrictEqual([{kind: LegKind.ride, chip: {name: "1_100275", color: ROUTE_COLOR_DEFAULT}}])
    const unnamed = journeyRows({journeys: [direct], nowMs: NOW_MS, serviceDayStartsMs, names: {stops: {}, routes: {}}, timeZone: TIME_ZONE})
    expect(unnamed[0].steps[0]).toBe("8:46 am board 1_100275 at 1_431")
  })

  // A journey that leaves on the next day reads "Tomorrow" before its time;
  // one that leaves before midnight and arrives after it is today's; one of
  // today's service date that leaves past midnight leaves tomorrow; one two
  // days on names its weekday; a walk alone leaves its walk before it arrives.
  test("the times text of each day", () => {
    const owl = {...pastMidnight, arrivalS: seconds("24:50"), legs: [ride({routeId: "1_100275", from: "1_431", departs: "24:10", to: "1_11920", arrives: "24:50"})]}
    const later = {...tomorrow, legs: [ride({routeId: "1_100275", from: "1_431", departs: "29:12", to: "1_11920", arrives: "29:40"})], arrivalS: seconds("29:40")}
    const walkOnly = {serviceDate: "2026-11-08", arrivalS: seconds("08:50"), changes: 0, isEarliest: true, legs: [walk({from: "1_431", to: "1_440", durationS: 300})], stopPositions: {}}
    const [tomorrowRow] = rowsOf({journeys: [tomorrow], nowMs: LATE_NOW_MS})
    const [pastMidnightRow] = rowsOf({journeys: [pastMidnight], nowMs: LATE_NOW_MS})
    const [owlRow] = rowsOf({journeys: [owl], nowMs: LATE_NOW_MS})
    const [laterRow] = rowsOf({journeys: [later], nowMs: LATE_NOW_MS})
    const [walkOnlyRow] = rowsOf({journeys: [walkOnly], nowMs: NOW_MS})
    expect(tomorrowRow.timesText).toBe("Tomorrow 5:12 am → 5:40 am")
    expect(pastMidnightRow.timesText).toBe("11:50 pm → 12:30 am")
    expect(owlRow.timesText).toBe("Tomorrow 12:10 am → 12:50 am")
    expect(laterRow.timesText).toBe("Tue 5:12 am → 5:40 am")
    expect(walkOnlyRow.timesText).toBe("8:45 am → 8:50 am")
  })

  // Arriving by a time, the latest journey is marked, and a journey leaves at
  // the time the router found.
  test("arriving by a time, the latest journey is marked", () => {
    const arrivingRows = rowsOf({journeys: [sooner, latest], nowMs: NOW_MS})
    expect(arrivingRows[0].badgeText).toBe("Latest · 28 min")
    expect(arrivingRows[0].isMarked).toBe(true)
    expect(arrivingRows[1].badgeText).toBe("20 min")
    expect(journeysAnnouncement(arrivingRows)).toBe("2 journeys. The latest leaves at 8:46 am.")
    expect(journeysAnnouncement([arrivingRows[0]])).toBe("1 journey. It leaves at 8:46 am.")
  })

  // The status line a screen reader hears once the journeys are written.
  test("the status line a screen reader hears", () => {
    const rows = rowsOf({journeys: [earliest, direct], nowMs: NOW_MS})
    const [tomorrowRow] = rowsOf({journeys: [tomorrow], nowMs: LATE_NOW_MS})
    const [pastMidnightRow] = rowsOf({journeys: [pastMidnight], nowMs: LATE_NOW_MS})
    expect(journeysAnnouncement(rows)).toBe("2 journeys. The earliest arrives at 9:02 am.")
    expect(journeysAnnouncement([rows[1]])).toBe("1 journey. It arrives at 9:02 am.")
    expect(journeysAnnouncement([tomorrowRow])).toBe("1 journey. It arrives tomorrow at 5:40 am.")
    expect(journeysAnnouncement([pastMidnightRow])).toBe("1 journey. It arrives at 12:30 am.")
  })

  // The window line names the mode and the time chosen, with the earliest
  // arrival plus 45 minutes, or the latest departure less 45 minutes.
  const windowCases = [
    {name: "now", planned: () => ({kind: PlannedKind.leaving, mode: TimeMode.now, ms: NOW_MS}), journeys: () => [earliest, direct], expected: "Leaving now · journeys arriving by 9:47 am"},
    {
      name: "a departure today",
      planned: () => ({kind: PlannedKind.leaving, mode: TimeMode.departAt, ms: HALF_EIGHT_MS}),
      journeys: () => [earliest, direct],
      expected: "Leaving at 8:30 am · journeys arriving by 9:47 am"
    },
    {
      name: "a departure tomorrow",
      planned: () => ({kind: PlannedKind.leaving, mode: TimeMode.departAt, ms: TOMORROW_START_MS + seconds("05:00") * SECOND_MS}),
      journeys: () => [tomorrow],
      expected: "Leaving at 5:00 am tomorrow · journeys arriving by 6:25 am"
    },
    {
      name: "an arrival tomorrow",
      planned: () => ({kind: PlannedKind.arrivingBy, mode: TimeMode.arriveBy, ms: NINE_TOMORROW_MS}),
      journeys: () => [{...latest, serviceDate: "2026-11-09"}, {...sooner, serviceDate: "2026-11-09"}],
      expected: "Arriving by 9:00 am tomorrow · journeys leaving from 8:01 am"
    }
  ]

  test.each(windowCases)("the window: $name", ({planned, journeys, expected}) => {
    const text = windowText({journeys: journeys(), nowMs: NOW_MS, serviceDayStartsMs, timeZone: TIME_ZONE, planned: planned()})
    expect(text).toBe(expected)
  })

  // A time on the page's clock, a day and an HH:MM, is the instant it names
  // in the time zone, across a change of daylight saving time too.
  const clockCases = [
    {name: "today", nowMs: NOW_MS, day: () => DayChoice.today, clockText: "09:00", expected: () => ({kind: ClockKind.valid, ms: TODAY_START_MS + seconds("09:00") * SECOND_MS})},
    {name: "tomorrow", nowMs: NOW_MS, day: () => DayChoice.tomorrow, clockText: "09:00", expected: () => ({kind: ClockKind.valid, ms: NINE_TOMORROW_MS})},
    {name: "midnight", nowMs: NOW_MS, day: () => DayChoice.tomorrow, clockText: "00:00", expected: () => ({kind: ClockKind.valid, ms: TOMORROW_START_MS})},
    {
      name: "the day standard time starts",
      nowMs: OCTOBER_31_AFTERNOON_MS,
      day: () => DayChoice.tomorrow,
      clockText: "09:00",
      expected: () => ({kind: ClockKind.valid, ms: NOVEMBER_1_START_MS + seconds("10:00") * SECOND_MS})
    },
    {
      name: "the evening before it",
      nowMs: OCTOBER_31_AFTERNOON_MS,
      day: () => DayChoice.today,
      clockText: "20:00",
      expected: () => ({kind: ClockKind.valid, ms: NOVEMBER_1_START_MS - seconds("04:00") * SECOND_MS})
    },
    {name: "no time", nowMs: NOW_MS, day: () => DayChoice.today, clockText: "", expected: () => ({kind: ClockKind.invalid})},
    {name: "not a time", nowMs: NOW_MS, day: () => DayChoice.today, clockText: "25:00", expected: () => ({kind: ClockKind.invalid})}
  ]

  test.each(clockCases)("the clock: $name", ({nowMs, day, clockText, expected}) => {
    const instant = wallClockMs({nowMs, day: day(), clockText, timeZone: TIME_ZONE})
    expect(instant).toStrictEqual(expected())
  })

  // A time chosen starts at the next five minutes, tomorrow past midnight.
  test("the default time", () => {
    expect(defaultClock({nowMs: NOW_MS, timeZone: TIME_ZONE})).toStrictEqual({day: DayChoice.today, clockText: "08:40"})
  })

  test("the default time at midnight", () => {
    const nearMidnightMs = TODAY_START_MS + seconds("23:58") * SECOND_MS
    expect(defaultClock({nowMs: nearMidnightMs, timeZone: TIME_ZONE})).toStrictEqual({day: DayChoice.tomorrow, clockText: "00:00"})
  })

  // What a query leaves at or arrives by, in the service date that holds it,
  // and a time no saved date holds refused with its own message.
  const plannedCases = [
    {
      name: "now",
      when: () => ({mode: TimeMode.now, day: DayChoice.today, clockText: "17:30"}),
      manifest: twoDays,
      expected: () => ({kind: PlannedKind.leaving, mode: TimeMode.now, ms: NOW_MS, serviceDate: "2026-11-08", seconds: seconds("08:38")})
    },
    {
      name: "a departure today",
      when: () => ({mode: TimeMode.departAt, day: DayChoice.today, clockText: "17:30"}),
      manifest: twoDays,
      expected: () => ({kind: PlannedKind.leaving, mode: TimeMode.departAt, ms: TODAY_START_MS + seconds("17:30") * SECOND_MS, serviceDate: "2026-11-08", seconds: seconds("17:30")})
    },
    {
      name: "an arrival tomorrow",
      when: () => ({mode: TimeMode.arriveBy, day: DayChoice.tomorrow, clockText: "09:00"}),
      manifest: twoDays,
      expected: () => ({kind: PlannedKind.arrivingBy, mode: TimeMode.arriveBy, ms: NINE_TOMORROW_MS, serviceDate: "2026-11-09", seconds: seconds("09:00")})
    },
    {
      name: "an arrival past midnight",
      when: () => ({mode: TimeMode.arriveBy, day: DayChoice.tomorrow, clockText: "00:45"}),
      manifest: twoDays,
      expected: () => ({kind: PlannedKind.arrivingBy, mode: TimeMode.arriveBy, ms: TOMORROW_START_MS + seconds("00:45") * SECOND_MS, serviceDate: "2026-11-09", seconds: seconds("00:45")})
    },
    {
      name: "a departure tomorrow no saved date holds",
      when: () => ({mode: TimeMode.departAt, day: DayChoice.tomorrow, clockText: "09:00"}),
      manifest: todayOnly,
      expected: () => ({kind: PlannedKind.refused, state: StateKind.outsideSchedules})
    },
    {
      name: "an arrival tomorrow no saved date holds",
      when: () => ({mode: TimeMode.arriveBy, day: DayChoice.tomorrow, clockText: "09:00"}),
      manifest: todayOnly,
      expected: () => ({kind: PlannedKind.refused, state: StateKind.outsideSchedules})
    },
    {
      name: "now with no saved date",
      when: () => ({mode: TimeMode.now, day: DayChoice.today, clockText: ""}),
      manifest: {formatVersion: 2, snapshots: []},
      expected: () => ({kind: PlannedKind.refused, state: StateKind.noServiceDate})
    },
    {
      name: "a departure with no time",
      when: () => ({mode: TimeMode.departAt, day: DayChoice.today, clockText: ""}),
      manifest: twoDays,
      expected: () => ({kind: PlannedKind.refused, state: StateKind.chooseTime})
    }
  ]

  test.each(plannedCases)("the planned time: $name", ({when, manifest, expected}) => {
    const planned = plannedTime({when: when(), nowMs: NOW_MS, timeZone: TIME_ZONE, manifest})
    expect(planned).toStrictEqual(expected())
  })

  // Two ends make a query once From is set and To is a stop or a point, and
  // never from a stop or a point to itself.
  const pike = stopEnd({stopId: "1_431", name: "3rd Ave & Pike St"})
  const othello = stopEnd({stopId: "1_11920", name: "Rainier Ave S & S Othello St"})
  const market = pointEnd({name: "Pike Place Market", lat: 47.6094, lon: -122.3422})
  const marketAgain = pointEnd({name: "Market", lat: 47.6094, lon: -122.3422})

  const queryCases = [
    {name: "no end", ends: {from: NO_END, to: NO_END}, expected: {kind: QueryKind.incomplete}},
    {name: "no To", ends: {from: LOCATION_END, to: NO_END}, expected: {kind: QueryKind.incomplete}},
    {name: "no From", ends: {from: NO_END, to: othello}, expected: {kind: QueryKind.incomplete}},
    {name: "one stop at both ends", ends: {from: pike, to: pike}, expected: {kind: QueryKind.sameStop}},
    {name: "one point at both ends", ends: {from: market, to: marketAgain}, expected: {kind: QueryKind.samePoint}},
    {name: "from a stop", ends: {from: pike, to: othello}, expected: {kind: QueryKind.ready, from: pike, to: othello}},
    {name: "from the location", ends: {from: LOCATION_END, to: othello}, expected: {kind: QueryKind.ready, from: LOCATION_END, to: othello}},
    {name: "from a point", ends: {from: market, to: othello}, expected: {kind: QueryKind.ready, from: market, to: othello}},
    {name: "to a point", ends: {from: pike, to: market}, expected: {kind: QueryKind.ready, from: pike, to: market}}
  ]

  test.each(queryCases)("query: $name", ({ends, expected}) => {
    expect(queryOf(ends)).toStrictEqual(expected)
  })

  // A swap moves each end to the other field, and the location, a From end
  // alone, leaves To empty.
  test("a swap moves each end to the other field", () => {
    expect(swappedEnds({from: pike, to: othello})).toStrictEqual({from: othello, to: pike})
    expect(swappedEnds({from: LOCATION_END, to: othello})).toStrictEqual({from: othello, to: NO_END})
    expect(swappedEnds({from: NO_END, to: othello}).from.kind).toBe(EndKind.stop)
  })

  // Every state has its headline and its caption.
  const stateMessageCases = [
    {kind: StateKind.loading, expected: {headline: "Finding journeys…", caption: "Searching today's and tomorrow's schedules."}},
    {kind: StateKind.noServiceDate, expected: {headline: "No schedule for this time yet", caption: "Try again later."}},
    {kind: StateKind.locationDenied, expected: {headline: "Location is off", caption: "Start from a stop instead, or allow location in your browser's settings."}},
    {kind: StateKind.locationUnavailable, expected: {headline: "Can't find your location", caption: "Start from a stop instead, or try again."}},
    {kind: StateKind.sameStop, expected: {headline: "From and To are the same stop", caption: "Choose another stop for one of them."}},
    {kind: StateKind.samePoint, expected: {headline: "From and To are the same place", caption: "Choose another place for one of them."}},
    {kind: StateKind.noEndStop, expected: {headline: "No stop within a walk of there", caption: "Choose a place nearer a stop."}},
    {kind: StateKind.notSaved, expected: {headline: "Not saved for offline", caption: "Connect to plan this trip."}},
    {kind: StateKind.outsideSchedules, expected: {headline: "No schedule for that time", caption: "Schedules cover today and tomorrow. Choose another time."}},
    {kind: StateKind.chooseTime, expected: {headline: "Choose a time", caption: "Set the time to plan this trip."}},
    {kind: StateKind.noneInTime, expected: {headline: "No journeys arrive in time", caption: "Nothing reaches this stop by then. Choose a later time."}},
    {kind: JourneysKind.none, expected: {headline: "No journeys found", caption: "Nothing runs between these two today or tomorrow."}},
    {kind: JourneysKind.unknownStop, expected: {headline: "Stop not in the schedules", caption: "Choose another stop nearby."}},
    {kind: JourneysKind.noStartStop, expected: {headline: "No stop within a walk", caption: "Start from a stop instead."}},
    {kind: JourneysKind.failed, expected: {headline: "Journeys didn't load", caption: "Check your connection and try again."}}
  ]

  test.each(stateMessageCases)("state message: $kind", ({kind, expected}) => {
    expect(stateMessage(kind)).toStrictEqual(expected)
  })

  test("every state of the tab and of the router has a case", () => {
    const routerStateKinds = [JourneysKind.none, JourneysKind.unknownStop, JourneysKind.noStartStop, JourneysKind.failed]
    const stateKindCount = Object.keys(StateKind).length + routerStateKinds.length
    expect(stateMessageCases.length).toBe(stateKindCount)
  })

  test("the message while a stop is picked", () => {
    expect(pickingMessage("From")).toStrictEqual({headline: "Pick a stop for From", caption: "Tap a stop on the map. Stops show once the map is zoomed in."})
  })

  // A query whose schedules are not saved says so, and any other failure says it failed.
  test("a schedule not saved and a fetch that failed", () => {
    expect(failureState({kind: JourneysKind.failed, reason: FailureReason.notSaved, path: ""})).toBe(StateKind.notSaved)
    expect(failureState({kind: JourneysKind.failed, reason: FailureReason.fetchFailed, path: ""})).toBe(JourneysKind.failed)
  })

  // The names asked for are the stops a leg boards, leaves, or walks between,
  // not the stops a ride only passes, and each ride's route, each once.
  test("the names asked for", () => {
    expect(nameRequest({journeys: [earliest, direct], countMax: NAME_COUNT_MAX})).toStrictEqual({
      stopIds: ["1_431", "1_1121", "1_1500", "1_11920"],
      routeIds: ["1_102576", "1_100210", "1_100275"]
    })
    expect(nameRequest({journeys: [earliest, direct], countMax: NAME_COUNT_MAX_TWO})).toStrictEqual({stopIds: ["1_431", "1_1121"], routeIds: ["1_102576", "1_100210"]})
  })

  // A trip's filter names the routes the journey rides, once each, in riding
  // order; a walk alone names none.
  test("a trip's filter names the routes it rides", () => {
    const backRide = ride({routeId: "1_102576", from: "1_11920", departs: "09:10", to: "1_431", arrives: "09:30"})
    const twice = {...earliest, legs: [...earliest.legs, backRide]}
    const walkAlone = {...earliest, legs: [walk({from: "1_431", to: "1_440", durationS: 60})]}
    expect(tripRouteIds({journey: earliest, countMax: ROUTE_COUNT_MAX})).toStrictEqual(["1_102576", "1_100210"])
    expect(tripRouteIds({journey: twice, countMax: ROUTE_COUNT_MAX})).toStrictEqual(["1_102576", "1_100210"])
    expect(tripRouteIds({journey: walkAlone, countMax: ROUTE_COUNT_MAX})).toStrictEqual([])
    expect(() => tripRouteIds({journey: earliest, countMax: ROUTE_COUNT_MAX_ONE})).toThrow(AssertionError)
  })

  // The map draws a line per ride through every stop it passes, in its
  // route's color, a line per walk, and the two ends.
  test("the map draws a journey's rides, walks, and ends", () => {
    const drawn = journeyFeatures({journey: earliest, names, origin: null})
    const drawnKinds = Array.from(drawn.collection.features, kindOf)
    expect(drawnKinds).toStrictEqual([FeatureKind.ride, FeatureKind.walk, FeatureKind.ride, FeatureKind.origin, FeatureKind.destination])
    const [firstRide, , , , destination] = drawn.collection.features
    expect(firstRide.geometry.coordinates).toStrictEqual([lonLat(PIKE), lonLat(PASSED), lonLat(CHERRY)])
    expect(firstRide.properties.color).toBe("#1D4ED8")
    expect(destination.geometry.coordinates).toStrictEqual(lonLat(OTHELLO))
    expect(drawn.bounds).toStrictEqual({kind: BoundsKind.bounds, bounds: [[PIKE.lon, OTHELLO.lat], [OTHELLO.lon, PIKE.lat]]})
  })

  // A journey from the rider's position starts its first walk there.
  test("a journey from the rider's position starts its first walk there", () => {
    const located = {...direct, legs: [{kind: LegKind.walkFromPosition, toStopId: "1_431", durationS: 240}, ...direct.legs]}
    const fromRider = journeyFeatures({journey: located, names, origin: RIDER})
    const [walkFromRider, , origin] = fromRider.collection.features
    expect(walkFromRider.geometry.coordinates).toStrictEqual([lonLat(RIDER), lonLat(PIKE)])
    expect(origin.geometry.coordinates).toStrictEqual(lonLat(RIDER))
  })

  function isDestinationFeature(feature) {
    return feature.properties.kind === FeatureKind.destination
  }

  // A journey to a point ends with the walk from its last stop: its summary,
  // its steps, the names it asks for, and the line the map draws to the point.
  test("a journey to a point ends with the walk from its last stop", () => {
    const toMarket = {
      ...direct,
      arrivalS: direct.arrivalS + 300,
      legs: [...direct.legs, {kind: LEG_KIND_TO_POINT, fromStopId: "1_11920", durationS: 300}],
      destination: {name: "Pike Place Market", ...MARKET}
    }
    const [marketRow] = rowsOf({journeys: [toMarket], nowMs: NOW_MS})
    expect(marketRow.summary[1]).toStrictEqual({kind: LegKind.walk, text: "walk 5 min"})
    const finalSteps = marketRow.steps.slice(marketRow.steps.length - FINAL_STEP_COUNT)
    expect(finalSteps).toStrictEqual(["walk 5 min to Pike Place Market", "9:19 am arrive at Pike Place Market"])
    const marketNames = nameRequest({journeys: [toMarket], countMax: NAME_COUNT_MAX})
    expect(marketNames.stopIds).toStrictEqual(["1_431", "1_11920"])
    const toPoint = journeyFeatures({journey: toMarket, names, origin: null})
    const walkToMarket = toPoint.collection.features[1]
    expect(walkToMarket.geometry.coordinates).toStrictEqual([lonLat(OTHELLO), lonLat(MARKET)])
    const destinationPoint = toPoint.collection.features.find(isDestinationFeature)
    expect(destinationPoint.geometry.coordinates).toStrictEqual(lonLat(MARKET))
  })

  // A journey whose stops have no known position draws nothing.
  test("a journey with no known position draws nothing", () => {
    const unplaced = journeyFeatures({journey: {...direct, stopPositions: {}}, names, origin: null})
    expect(featureCount(unplaced.collection)).toBe(0)
    expect(unplaced.bounds).toStrictEqual({kind: BoundsKind.none})
  })
})
