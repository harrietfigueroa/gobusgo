// Checks the vehicle page's trip path decoder and cache as pure functions:
// the decoder reads the shared fixture the Elixir tests pin to the server's
// builder, the stored loop trip 1_1137791 of route 1_7994, and must find
// its points and each stop's distance and times, and must refuse each case of
// the shared refusal table with its message; the cache is fed paths written
// out by hand.

import {beforeAll, describe, expect, test} from "vitest"
import {fixtureJson} from "../fixtures.mjs"
import {implementationsWith} from "../implementations.mjs"

const DISTANCE_TOLERANCE_M = 1

// The cases name the tests, so they are read before the tests are collected.
const {cases: refusalCases} = await fixtureJson("one_bus_away/trip_path/refusals.json")

// The event with the one field a refusal case changes.
function refusedEvent({field, value, append}, event) {
  if (append === undefined) {
    return {...event, [field]: value}
  }

  return {...event, [field]: event[field] + append}
}

function stopDistance(stop) {
  return stop.distanceMeters
}

function stopArrival(stop) {
  return stop.arrivalSeconds
}

function stopDeparture(stop) {
  return stop.departureSeconds
}

let event = null
let expected = null

beforeAll(async () => {
  const fixture = await fixtureJson("one_bus_away/trip_path/encoded_loop.json")
  event = fixture.event
  expected = fixture.expected
})

describe.each(implementationsWith("geodesy", "tripPath"))("trip path ($name)", ({AssertionError, geodesy, tripPath}) => {
  const {decodeTripPath, tripPathKey, tripPathOf} = tripPath

  test("the point count", () => {
    expect(decodeTripPath(event).points.length).toBe(expected.pointCount)
  })

  test("the first point", () => {
    expect(decodeTripPath(event).points[0]).toStrictEqual(expected.firstPoint)
  })

  test("the last point", () => {
    const decoded = decodeTripPath(event)
    const lastPoint = decoded.points[decoded.points.length - 1]
    expect(lastPoint).toStrictEqual(expected.lastPoint)
  })

  test("the stop distances", () => {
    const decoded = decodeTripPath(event)
    const distances = Array.from(decoded.stops, stopDistance)
    expect(distances).toStrictEqual(expected.stopDistancesM)
  })

  test("the arrivals", () => {
    const decoded = decodeTripPath(event)
    const arrivals = Array.from(decoded.stops, stopArrival)
    expect(arrivals).toStrictEqual(expected.arrivalS)
  })

  test("the departures", () => {
    const decoded = decodeTripPath(event)
    const departures = Array.from(decoded.stops, stopDeparture)
    expect(departures).toStrictEqual(expected.departureS)
  })

  test("the key", () => {
    const eventKey = tripPathKey({tripId: event.trip_id, serviceDateMs: event.service_date_ms})
    expect(decodeTripPath(event).key).toBe(eventKey)
  })

  // The server measures a stop's distance over the same rounded points by the
  // same formula, so the length of the decoded points is the last stop's
  // distance.
  test("the length along the points", () => {
    const decoded = decodeTripPath(event)
    let lengthMeters = 0

    for (let index = 1; index < decoded.points.length; index += 1) {
      lengthMeters += geodesy.distanceMeters(decoded.points[index - 1], decoded.points[index])
    }

    expect(Math.abs(lengthMeters - expected.lengthM)).toBeLessThanOrEqual(DISTANCE_TOLERANCE_M)
  })

  test("the decoded path is frozen", () => {
    const decoded = decodeTripPath(event)
    expect(Object.isFrozen(decoded)).toBe(true)
  })

  test("a decoded stop is frozen", () => {
    expect(Object.isFrozen(decodeTripPath(event).stops[0])).toBe(true)
  })

  test.each(refusalCases)("refused: $name", (refusal) => {
    const refusedPath = refusedEvent(refusal, event)
    const failing = () => decodeTripPath(refusedPath)
    expect(failing).toThrow(AssertionError)
    expect(failing).toThrow(new AssertionError(refusal.failure))
  })

  // Distances written as text: JavaScript compares "10" before "9" as text,
  // and the binding takes no value a caller hands as a number unless it is one.
  test("a built path whose stop distances are text is refused", () => {
    const textStops = [{distanceMeters: "9"}, {distanceMeters: "10"}]
    const parts = {tripId: event.trip_id, routeId: event.route_id, serviceDateMs: event.service_date_ms, points: [[0, 0]], stops: textStops}
    expect(() => tripPathOf(parts)).toThrow(AssertionError)
  })
})

// The page's bounded cache holds the page's own objects, so the web keeps it
// in JavaScript and the WebAssembly binding exports none; an entry runs these
// cases where its trip path module holds the cache.
function holdsTripPathCache({tripPath}) {
  return "withTripPaths" in tripPath
}

const cacheImplementations = implementationsWith("tripPath").filter(holdsTripPathCache)

describe.each(cacheImplementations)("trip path cache ($name)", ({tripPath}) => {
  const {TRIP_PATH_COUNT_MAX, tripPathKey, withTripPaths} = tripPath

  function heldPath(name) {
    return {key: tripPathKey({tripId: "trip_" + name, serviceDateMs: event.service_date_ms})}
  }

  function overflowingCache() {
    const overflowing = []

    for (let index = 0; index <= TRIP_PATH_COUNT_MAX; index += 1) {
      overflowing.push(heldPath(index))
    }

    return withTripPaths(new Map(), overflowing)
  }

  test("the cache holds no more paths than its bound", () => {
    expect(overflowingCache().size).toBe(TRIP_PATH_COUNT_MAX)
  })

  test("the cache evicts the path put earliest", () => {
    expect(overflowingCache().has(heldPath(0).key)).toBe(false)
  })

  test("the cache keeps the path put last", () => {
    expect(overflowingCache().has(heldPath(TRIP_PATH_COUNT_MAX).key)).toBe(true)
  })

  test("the cache given is left as it was", () => {
    const empty = new Map()
    withTripPaths(empty, [heldPath("first")])
    expect(empty.size).toBe(0)
  })

  test("a path put again moves to the back", () => {
    const firstPath = heldPath("first")
    const secondPath = heldPath("second")
    const both = withTripPaths(new Map(), [firstPath, secondPath])
    const moved = withTripPaths(both, [firstPath])
    const movedKeys = Array.from(moved.keys())
    expect(movedKeys).toStrictEqual([secondPath.key, firstPath.key])
  })
})
