// Checks how the Trip tab routes to a point that is not a stop, as pure
// functions over positions and router answers written out by hand: the
// stops a destination walks from, and the one frontier the answers to each
// of those stops make once the walk is added, the earliest arrival or the
// latest departure, with the best marked and the window applied.

import {describe, expect, test} from "vitest"
import {IMPLEMENTATIONS} from "../implementations.mjs"

const MICRODEGREES = 1_000_000
const MINUTE_S = 60
const DAY_MS = 24 * 60 * 60 * 1000
const TODAY = "2026-11-08"
const TOMORROW = "2026-11-09"
const TODAY_START_MS = 1794124800000
const serviceDayStartsMs = {[TODAY]: TODAY_START_MS, [TOMORROW]: TODAY_START_MS + DAY_MS}
const destination = {name: "Pike Place Market", lat: 47.6094, lon: -122.3422}
const transferRules = {walkRadiusM: 400, walkSpeedMPerS: 1.2, walkLinkCountPerStopMax: 64, minimumTransferS: 120}
const RIDE_MINUTES = 10
const LONG_RIDE_MINUTES = 20
const RIDE_S = RIDE_MINUTES * MINUTE_S
const LONG_RIDE_S = LONG_RIDE_MINUTES * MINUTE_S
const ONE_STOP = 1
const NO_CHANGE = 0
const ONE_CHANGE = 1
const NO_WALK_S = 0
const WALK_A_S = 120
const WALK_B_S = 60
const TIME_S = 1000
const EARLIER_S = 800
const LATER_S = 1100
const LATEST_S = 1300
const LATE_TODAY_S = 86000
const EARLY_TOMORROW_S = 100
// The haversine distances from the destination at 1.2 m/s, rounded up:
// 30.0 m and 75.8 m.
const NEARER_WALK_S = 25
const NEAR_WALK_S = 64

function micro(degrees) {
  return Math.round(degrees * MICRODEGREES)
}

function latOf(point) {
  return micro(point.lat)
}

function lonOf(point) {
  return micro(point.lon)
}

function positionsOf(points) {
  return {latMicrodegrees: Int32Array.from(points, latOf), lonMicrodegrees: Int32Array.from(points, lonOf)}
}

function stopIdOf(target) {
  return target.stopId
}

function walkOf(target) {
  return target.walkS
}

function serviceDateOf(kept) {
  return kept.serviceDate
}

function arrivalRow(kept) {
  return [kept.arrivalS, kept.changes, kept.isEarliest]
}

function departureRow(kept) {
  return [kept.departureS, kept.changes, kept.isLatest]
}

function lastLeg(kept) {
  return kept.legs[kept.legs.length - 1]
}

describe.each(IMPLEMENTATIONS)("point journeys ($name)", ({AssertionError, pointJourneys, routingEngine, routingJourneys, routingSnapshot}) => {
  const {LegKind} = routingEngine
  const {FailureReason, JourneysKind, WINDOW_SECONDS} = routingJourneys
  const {POSITION_UNKNOWN_MICRODEGREES} = routingSnapshot
  const {FrontierKind, LEG_KIND_TO_POINT, PointJourneysKind, TARGET_STOP_COUNT_MAX, journeysToPoint, targetStops} = pointJourneys

  function journey({stopId, arrivalS, changes, serviceDate = TODAY}) {
    const ride = {kind: LegKind.ride, routeId: "1_100", tripId: "t", fromStopId: "1_1", toStopId: stopId, departureS: arrivalS - RIDE_S, arrivalS, stopIds: ["1_1", stopId], serviceDayOffset: 0}
    return {serviceDate, arrivalS, changes, legs: [ride], stopPositions: {}, isEarliest: false}
  }

  function leaving({stopId, departureS, changes}) {
    const left = journey({stopId, arrivalS: departureS + LONG_RIDE_S, changes})
    return {...left, departureS, isLatest: false}
  }

  function found(journeys) {
    return {kind: JourneysKind.found, journeys, loaded: {chunkCount: 1, byteCount: 1}}
  }

  // The stops within a walk of the destination, nearest first, each with its
  // walk; a stop with no known position and one past the radius are left out.
  test("the stops within a walk of the destination, nearest first", () => {
    const near = {lat: 47.6095, lon: -122.3412}
    const nearer = {lat: 47.6094, lon: -122.3418}
    const far = {lat: 47.62, lon: -122.34}
    const placed = positionsOf([near, far, nearer])
    const positions = {
      latMicrodegrees: Int32Array.from([...placed.latMicrodegrees, POSITION_UNKNOWN_MICRODEGREES]),
      lonMicrodegrees: Int32Array.from([...placed.lonMicrodegrees, POSITION_UNKNOWN_MICRODEGREES])
    }
    const stopIds = ["1_near", "1_far", "1_nearer", "1_unknown"]
    const targets = targetStops({position: destination, stopIds, positions, transferRules, countMax: TARGET_STOP_COUNT_MAX})
    const targetIds = Array.from(targets, stopIdOf)
    const walks = Array.from(targets, walkOf)
    expect(targetIds).toStrictEqual(["1_nearer", "1_near"])
    expect(walks).toStrictEqual([NEARER_WALK_S, NEAR_WALK_S])

    const boundedStopIds = ["1_near", "1_far", "1_nearer"]
    const bounded = targetStops({position: destination, stopIds: boundedStopIds, positions: placed, transferRules, countMax: ONE_STOP})
    expect(bounded.length).toBe(ONE_STOP)
    const twoPlaced = positionsOf([near, far])
    expect(() => targetStops({position: destination, stopIds: ["1_near"], positions: twoPlaced, transferRules, countMax: ONE_STOP})).toThrow(AssertionError)
  })

  // Each journey gains the walk from its stop, and the answers make one
  // frontier: a journey is kept when it arrives earlier than every one with
  // no more changes, the earliest is marked, and the window counts from it.
  test("the frontier of the earliest arrival", () => {
    const aJourneys = [journey({stopId: "1_a", arrivalS: TIME_S, changes: NO_CHANGE}), journey({stopId: "1_a", arrivalS: EARLIER_S, changes: ONE_CHANGE})]
    const bJourneys = [journey({stopId: "1_b", arrivalS: TIME_S, changes: NO_CHANGE}), journey({stopId: "1_b", arrivalS: TIME_S + WINDOW_SECONDS, changes: NO_CHANGE})]
    const toA = found(aJourneys)
    const toB = found(bJourneys)
    const routed = [{target: {stopId: "1_a", walkS: WALK_A_S}, answer: toA}, {target: {stopId: "1_b", walkS: WALK_B_S}, answer: toB}]
    const answer = journeysToPoint({routed, destination, serviceDayStartsMs, frontier: FrontierKind.earliestArrival})
    const rows = Array.from(answer.journeys, arrivalRow)
    expect(answer.kind).toBe(PointJourneysKind.found)
    expect(rows).toStrictEqual([[TIME_S + WALK_B_S, NO_CHANGE, false], [EARLIER_S + WALK_A_S, ONE_CHANGE, true]])
    expect(lastLeg(answer.journeys[0])).toStrictEqual({kind: LEG_KIND_TO_POINT, fromStopId: "1_b", durationS: WALK_B_S})
    expect(answer.journeys[0].destination).toStrictEqual(destination)
  })

  // A journey of the next service date compares on one timeline with today's.
  test("a journey of the next service date compares on one timeline", () => {
    const tomorrowJourney = journey({stopId: "1_a", arrivalS: EARLY_TOMORROW_S, changes: NO_CHANGE, serviceDate: TOMORROW})
    const todayJourney = journey({stopId: "1_b", arrivalS: LATE_TODAY_S, changes: NO_CHANGE})
    const tomorrow = found([tomorrowJourney])
    const today = found([todayJourney])
    const routed = [{target: {stopId: "1_a", walkS: NO_WALK_S}, answer: tomorrow}, {target: {stopId: "1_b", walkS: NO_WALK_S}, answer: today}]
    const answer = journeysToPoint({routed, destination, serviceDayStartsMs, frontier: FrontierKind.earliestArrival})
    const dates = Array.from(answer.journeys, serviceDateOf)
    expect(dates).toStrictEqual([TODAY])
  })

  // Arriving by a time, the answers make the frontier of the latest
  // departure: a journey is kept when it leaves later than every one with no
  // more changes, the latest is marked, and the window counts back from it.
  test("the frontier of the latest departure", () => {
    const aJourneys = [leaving({stopId: "1_a", departureS: TIME_S, changes: NO_CHANGE}), leaving({stopId: "1_a", departureS: LATEST_S, changes: ONE_CHANGE})]
    const bJourneys = [leaving({stopId: "1_b", departureS: LATER_S, changes: NO_CHANGE}), leaving({stopId: "1_b", departureS: LATER_S - WINDOW_SECONDS - 1, changes: NO_CHANGE})]
    const toA = found(aJourneys)
    const toB = found(bJourneys)
    const routed = [{target: {stopId: "1_a", walkS: WALK_A_S}, answer: toA}, {target: {stopId: "1_b", walkS: WALK_B_S}, answer: toB}]
    const answer = journeysToPoint({routed, destination, serviceDayStartsMs, frontier: FrontierKind.latestDeparture})
    const rows = Array.from(answer.journeys, departureRow)
    expect(rows).toStrictEqual([[LATER_S, NO_CHANGE, false], [LATEST_S, ONE_CHANGE, true]])
    expect(lastLeg(answer.journeys[0])).toStrictEqual({kind: LEG_KIND_TO_POINT, fromStopId: "1_b", durationS: WALK_B_S})
  })

  // No journey to any stop is none, a start with no stop is that for every
  // stop, and with no journey found a failure is the first failure.
  test("none, no start stop, and the first failure", () => {
    const none = {kind: JourneysKind.none, loaded: {chunkCount: 0, byteCount: 0}}
    const failed = {kind: JourneysKind.failed, reason: FailureReason.fetchFailed, path: "/routing/x"}
    const noStart = {kind: JourneysKind.noStartStop}
    const target = {stopId: "1_a", walkS: NO_WALK_S}
    const frontier = FrontierKind.earliestArrival
    const noneAnswer = journeysToPoint({routed: [{target, answer: none}], destination, serviceDayStartsMs, frontier})
    expect(noneAnswer.kind).toBe(JourneysKind.none)
    const noStartAnswer = journeysToPoint({routed: [{target, answer: noStart}], destination, serviceDayStartsMs, frontier})
    expect(noStartAnswer.kind).toBe(JourneysKind.noStartStop)
    const failedAnswer = journeysToPoint({routed: [{target, answer: failed}, {target, answer: none}], destination, serviceDayStartsMs, frontier})
    expect(failedAnswer).toStrictEqual(failed)
    const reachedJourney = journey({stopId: "1_a", arrivalS: TIME_S, changes: NO_CHANGE})
    const reached = found([reachedJourney])
    const partly = journeysToPoint({routed: [{target, answer: failed}, {target, answer: reached}], destination, serviceDayStartsMs, frontier})
    expect(partly.kind).toBe(PointJourneysKind.found)
    expect(() => journeysToPoint({routed: [], destination, serviceDayStartsMs, frontier})).toThrow(AssertionError)
  })
})
