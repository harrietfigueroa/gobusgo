// A running trip's path as the vehicle page receives it, decoded, and the
// page's bounded cache of the paths it holds. Everything here is pure: a
// decoder takes the event's values, and the cache's functions take a cache
// and return another, leaving the one given as it was.
//
// A path arrives with `points` in the encoded polyline format and `stops`
// as three numbers per stop in the same format's number encoding: the
// distance since the stop before in meters, the arrival since the stop
// before's arrival in seconds, and the departure after the arrival, the
// first stop's taken from zero.
// https://developers.google.com/maps/documentation/utilities/polylinealgorithm — checked 2026-11-09

import {assertCondition} from "./assert.js"
// The most paths the page holds.
export const TRIP_PATH_COUNT_MAX = 300

const CHARACTER_OFFSET = 63
const CHARACTER_MAX = 126
const CHUNK_BITS = 5
const CHUNK_MASK = 0x1F
const CHUNK_CONTINUES = 0x20
// Seven chunks hold 35 bits, of which the bit operators keep 32, enough
// for every number a path holds: a coordinate times 100,000 and doubled
// for its sign, a distance, or a time.
const NUMBER_CHUNK_COUNT_MAX = 7
const COORDINATE_PRECISION = 100000
// A point is two numbers, latitude then longitude; a stop is three, its
// distance step, its arrival step, and its dwell.
const NUMBERS_PER_POINT = 2
const LONGITUDE_OFFSET = 1
const NUMBERS_PER_STOP = 3
const ARRIVAL_OFFSET = 1
const DWELL_OFFSET = 2

// The numbers `encoded` holds, each written lowest chunk first with its
// sign in the lowest bit. A number of more chunks than the bound is refused
// rather than read wrong.
function decodeNumbers(encoded) {
  assertCondition(typeof encoded === "string", "encoded numbers must be a string")
  const numbers = []
  let value = 0
  let chunkCount = 0

  for (let index = 0; index < encoded.length; index += 1) {
    const code = encoded.charCodeAt(index)
    assertCondition(code >= CHARACTER_OFFSET, "character " + index + " lies below the encoded format")
    assertCondition(code <= CHARACTER_MAX, "character " + index + " lies above the encoded format")
    const chunk = code - CHARACTER_OFFSET
    value = value | ((chunk & CHUNK_MASK) << (chunkCount * CHUNK_BITS))
    chunkCount += 1
    assertCondition(chunkCount <= NUMBER_CHUNK_COUNT_MAX, "a number holds at most " + NUMBER_CHUNK_COUNT_MAX + " chunks")

    if (chunk < CHUNK_CONTINUES) {
      numbers.push(signedNumber(value))
      value = 0
      chunkCount = 0
    }
  }

  assertCondition(chunkCount === 0, "the encoded text ends inside a number")
  return numbers
}

// The lowest bit carries the sign.
function signedNumber(value) {
  const negative = (value & 1) === 1

  if (negative) {
    return ~(value >>> 1)
  }
  return value >>> 1
}

function decodePoints(encoded) {
  const numbers = decodeNumbers(encoded)
  assertCondition(numbers.length % NUMBERS_PER_POINT === 0, "a point holds a latitude and a longitude")
  const points = []
  let latitude = 0
  let longitude = 0

  for (let index = 0; index < numbers.length; index += NUMBERS_PER_POINT) {
    latitude += numbers[index]
    longitude += numbers[index + LONGITUDE_OFFSET]
    points.push(Object.freeze([longitude / COORDINATE_PRECISION, latitude / COORDINATE_PRECISION]))
  }

  return points
}

function decodeStops(encoded) {
  const numbers = decodeNumbers(encoded)
  assertCondition(numbers.length % NUMBERS_PER_STOP === 0, "a stop holds three numbers")
  const stops = []
  let distanceMeters = 0
  let arrivalSeconds = 0

  for (let index = 0; index < numbers.length; index += NUMBERS_PER_STOP) {
    distanceMeters += numbers[index]
    arrivalSeconds += numbers[index + ARRIVAL_OFFSET]
    const departureSeconds = arrivalSeconds + numbers[index + DWELL_OFFSET]
    stops.push(Object.freeze({distanceMeters, arrivalSeconds, departureSeconds}))
  }

  return stops
}

/**
 * The key a path is held under: its trip and the start of its service day,
 * in milliseconds since the Unix epoch.
 */
export function tripPathKey({tripId, serviceDateMs}) {
  assertCondition(typeof tripId === "string", "a trip identifier must be text")
  assertCondition(tripId !== "", "a trip identifier must not be empty")
  assertCondition(Number.isSafeInteger(serviceDateMs), "a service date must be an integer")
  return serviceDateMs + "/" + tripId
}

/**
 * One encoded path, decoded: its points, longitude
 * first, and each stop's distance along them in meters and its scheduled
 * times in seconds from `serviceDateMs`, in the order the trip serves them.
 * A stop's distance is the sum of haversine distances between the points
 * on a sphere of radius 6,371,008.8 m.
 */
export function decodeTripPath(path) {
  const {trip_id: tripId, route_id: routeId, service_date_ms: serviceDateMs} = path
  const points = decodePoints(path.points)
  const stops = decodeStops(path.stops)
  return tripPathOf({tripId, routeId, serviceDateMs, points, stops})
}

/**
 * The decoded path of `tripId` on the service day that starts at
 * `serviceDateMs`: `points`, each a frozen `[longitude, latitude]` in
 * degrees, and `stops`, each a frozen `{distanceMeters, arrivalSeconds,
 * departureSeconds}`, with at least one of each and no stop before the stop
 * before it. Every decoder of a path builds its result here, so a path has
 * one shape wherever it was read from.
 */
export function tripPathOf({tripId, routeId, serviceDateMs, points, stops}) {
  assertCondition(points.length > 0, "a path holds at least one point")
  assertCondition(stops.length > 0, "a path holds at least one stop")

  for (let index = 1; index < stops.length; index += 1) {
    const ordered = stops[index].distanceMeters >= stops[index - 1].distanceMeters
    assertCondition(ordered, "stop " + index + " lies before the stop before it")
  }

  return Object.freeze({
    tripId,
    routeId,
    serviceDateMs,
    key: tripPathKey({tripId, serviceDateMs}),
    points: Object.freeze(points),
    stops: Object.freeze(stops)
  })
}

/**
 * A cache holding `cache`'s paths and `paths`, decoded paths, at most
 * TRIP_PATH_COUNT_MAX of them: a path put again moves to the back, and the
 * paths put earliest leave first.
 */
export function withTripPaths(cache, paths) {
  const next = new Map(cache)

  for (const path of paths) {
    next.delete(path.key)
    next.set(path.key, path)
  }

  for (const key of next.keys()) {
    if (next.size <= TRIP_PATH_COUNT_MAX) {
      break
    }
    next.delete(key)
  }

  return next
}
