// Checks the geodesy module against values known by construction on the
// sphere of the mean radius: a degree of a meridian, a quarter of the
// equator, a degree across the antimeridian, and the bearings of the four
// compass directions, and against the bearing of a published example. It
// checks the tangent plane's scale bound over a city's span and past it,
// and that a position the module refuses is refused. Run it with
// `node test/scripts/geodesy_check.mjs`; it exits non-zero on the first
// case that differs.

import {ok, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/assert.js"
import {
  EARTH_RADIUS_METERS,
  METERS_PER_DEGREE,
  assertPlaneCovers,
  assertPosition,
  distanceMeters,
  initialBearingDegrees,
  metersPerDegreeLongitude,
  tangentPlane
} from "../../assets/js/math/geodesy.js"

// Far finer than a reported position, and coarser than the rounding of a
// sum of a few products of doubles.
const TOLERANCE_METERS = 1e-6
const TOLERANCE_DEGREES = 1e-9

const NORTH_DEGREES = 0
const EAST_DEGREES = 90
const SOUTH_DEGREES = 180
const WEST_DEGREES = 270
const TURN_DEGREES = 360
const HALF_EQUATOR_METERS = Math.PI * EARTH_RADIUS_METERS
const HALVES_PER_WHOLE = 2
const QUARTER_EQUATOR_METERS = HALF_EQUATOR_METERS / HALVES_PER_WHOLE
const COSINE_OF_SIXTY_DEGREES = 0.5
const SIXTY_DEGREES = 60

// Baghdad, 35° N 45° E, to Osaka, 35° N 135° E, starts at a bearing of 60°
// to the degree.
// https://www.movable-type.co.uk/scripts/latlong.html#bearing — checked 2026-11-09
const BAGHDAD_TO_OSAKA_DEGREES = 60
const PAST_POLE_LATITUDE = 91

const places = {
  origin: {lon: 0, lat: 0},
  oneNorth: {lon: 0, lat: 1},
  oneEast: {lon: 1, lat: 0},
  oneWest: {lon: -1, lat: 0},
  quarterEast: {lon: 90, lat: 0},
  antipode: {lon: 180, lat: 0},
  equatorUnderSeattle: {lon: -122, lat: 0},
  poleOverSeattle: {lon: -122, lat: 90},
  westOfAntimeridian: {lon: 179.5, lat: 0},
  eastOfAntimeridian: {lon: -179.5, lat: 0},
  seattle: {lon: -122.3321, lat: 47.6062},
  northOfSeattle: {lon: -122.3321, lat: 47.7},
  southOfSeattle: {lon: -122.3321, lat: 47.5},
  northWestOfSeattle: {lon: -122.4, lat: 47.7},
  tacoma: {lon: -122.4443, lat: 47.2529},
  baghdad: {lon: 45, lat: 35},
  osaka: {lon: 135, lat: 35},
  pastLongitude: {lon: 180.5, lat: 0},
  pastLatitude: {lon: 0, lat: -90.5}
}

function positionOf({lon, lat}) {
  return [lon, lat]
}

const ORIGIN = positionOf(places.origin)
const ONE_NORTH = positionOf(places.oneNorth)
const ONE_EAST = positionOf(places.oneEast)
const ONE_WEST = positionOf(places.oneWest)
const QUARTER_EAST = positionOf(places.quarterEast)
const ANTIPODE = positionOf(places.antipode)
const EQUATOR_UNDER_SEATTLE = positionOf(places.equatorUnderSeattle)
const POLE_OVER_SEATTLE = positionOf(places.poleOverSeattle)
const WEST_OF_ANTIMERIDIAN = positionOf(places.westOfAntimeridian)
const EAST_OF_ANTIMERIDIAN = positionOf(places.eastOfAntimeridian)
const SEATTLE = positionOf(places.seattle)
const NORTH_OF_SEATTLE = positionOf(places.northOfSeattle)
const SOUTH_OF_SEATTLE = positionOf(places.southOfSeattle)
const NORTH_WEST_OF_SEATTLE = positionOf(places.northWestOfSeattle)
const TACOMA = positionOf(places.tacoma)
const BAGHDAD = positionOf(places.baghdad)
const OSAKA = positionOf(places.osaka)

function near({actual, expected, tolerance, message}) {
  ok(Math.abs(actual - expected) <= tolerance, `${message}: ${actual} is not ${expected}`)
}

const distanceCases = [
  {name: "one position", source: SEATTLE, target: SEATTLE, meters: 0},
  {name: "a degree of the prime meridian", source: ORIGIN, target: ONE_NORTH, meters: METERS_PER_DEGREE},
  {name: "a degree of the equator", source: ORIGIN, target: ONE_EAST, meters: METERS_PER_DEGREE},
  {name: "a quarter of the equator", source: ORIGIN, target: QUARTER_EAST, meters: QUARTER_EQUATOR_METERS},
  {name: "a pole from the equator", source: EQUATOR_UNDER_SEATTLE, target: POLE_OVER_SEATTLE, meters: QUARTER_EQUATOR_METERS},
  {name: "a degree across the antimeridian", source: WEST_OF_ANTIMERIDIAN, target: EAST_OF_ANTIMERIDIAN, meters: METERS_PER_DEGREE},
  {name: "antipodes", source: ORIGIN, target: ANTIPODE, meters: HALF_EQUATOR_METERS}
]

for (const {name, source, target, meters} of distanceCases) {
  near({actual: distanceMeters(source, target), expected: meters, tolerance: TOLERANCE_METERS, message: name})
}

// A distance is the same either way.
near({actual: distanceMeters(TACOMA, SEATTLE), expected: distanceMeters(SEATTLE, TACOMA), tolerance: 0, message: "Tacoma and Seattle either way"})

// A degree of longitude shortens with the cosine of the latitude.
near({actual: metersPerDegreeLongitude(0), expected: METERS_PER_DEGREE, tolerance: TOLERANCE_METERS, message: "a degree of longitude at the equator"})
const sixtyExpected = METERS_PER_DEGREE * COSINE_OF_SIXTY_DEGREES
near({actual: metersPerDegreeLongitude(SIXTY_DEGREES), expected: sixtyExpected, tolerance: TOLERANCE_METERS, message: "a degree of longitude at 60°"})

const bearingCases = [
  {name: "due north", source: SEATTLE, target: NORTH_OF_SEATTLE, degrees: NORTH_DEGREES},
  {name: "due east along the equator", source: ORIGIN, target: ONE_EAST, degrees: EAST_DEGREES},
  {name: "due south", source: SEATTLE, target: SOUTH_OF_SEATTLE, degrees: SOUTH_DEGREES},
  {name: "due west along the equator", source: ORIGIN, target: ONE_WEST, degrees: WEST_DEGREES},
  {name: "east across the antimeridian", source: WEST_OF_ANTIMERIDIAN, target: EAST_OF_ANTIMERIDIAN, degrees: EAST_DEGREES},
  {name: "one position", source: SEATTLE, target: SEATTLE, degrees: NORTH_DEGREES}
]

for (const {name, source, target, degrees} of bearingCases) {
  near({actual: initialBearingDegrees(source, target), expected: degrees, tolerance: TOLERANCE_DEGREES, message: name})
}

const baghdadToOsaka = initialBearingDegrees(BAGHDAD, OSAKA)
near({actual: Math.round(baghdadToOsaka), expected: BAGHDAD_TO_OSAKA_DEGREES, tolerance: 0, message: "Baghdad to Osaka"})

// A bearing is 0 or more and below a whole turn.
const northWest = initialBearingDegrees(SEATTLE, NORTH_WEST_OF_SEATTLE)
ok(northWest > WEST_DEGREES, `north-west is ${northWest}`)
ok(northWest < TURN_DEGREES, `north-west is ${northWest}`)

const refusedPositions = [
  {name: "a pair of no length", position: []},
  {name: "a longitude past 180", position: positionOf(places.pastLongitude)},
  {name: "a latitude past 90", position: positionOf(places.pastLatitude)},
  {name: "a latitude that is no number", position: [0, Number.NaN]},
  {name: "an object", position: {lon: 0, lat: 0}}
]

for (const {name, position} of refusedPositions) {
  throws(assertPositionOf({position, name}), AssertionError, name)
}

function assertPositionOf({position, name}) {
  return function assertNamedPosition() {
    assertPosition(position, name)
  }
}

// A plane tangent at Seattle covers the half degree around it, a city's
// span, and not the latitude of Vancouver or of Portland, at whose edges a
// plane at Seattle's latitude is more than 2% off; a plane by the equator
// covers a span across it, and a plane by the pole covers no span.
const seattlePlane = tangentPlane({referenceLatitudeDegrees: SEATTLE[1]})
near({actual: seattlePlane.metersPerDegreeLon, expected: metersPerDegreeLongitude(SEATTLE[1]), tolerance: 0, message: "Seattle's plane"})
const quitoPlane = tangentPlane({referenceLatitudeDegrees: 0.5})
const polarPlane = tangentPlane({referenceLatitudeDegrees: 89.9})

const coveredSpans = [
  {name: "Seattle's plane over the city", plane: seattlePlane, latitudeDegreesMin: 47.35, latitudeDegreesMax: 47.85},
  {name: "a plane by the equator across it", plane: quitoPlane, latitudeDegreesMin: -0.5, latitudeDegreesMax: 1}
]

for (const {plane, latitudeDegreesMin, latitudeDegreesMax} of coveredSpans) {
  assertPlaneCovers({plane, latitudeDegreesMin, latitudeDegreesMax})
}

const refusedSpans = [
  {name: "Seattle's plane at Vancouver", plane: seattlePlane, latitudeDegreesMin: 47.35, latitudeDegreesMax: 49.3},
  {name: "Seattle's plane at Portland", plane: seattlePlane, latitudeDegreesMin: 45.5, latitudeDegreesMax: 47.85},
  {name: "latitudes out of order", plane: seattlePlane, latitudeDegreesMin: 48, latitudeDegreesMax: 47},
  {name: "a plane by the pole", plane: polarPlane, latitudeDegreesMin: 89.8, latitudeDegreesMax: 89.9}
]

for (const span of refusedSpans) {
  throws(assertSpanOf(span), AssertionError, span.name)
}

function assertSpanOf({plane, latitudeDegreesMin, latitudeDegreesMax}) {
  return function assertSpan() {
    assertPlaneCovers({plane, latitudeDegreesMin, latitudeDegreesMax})
  }
}

throws(distanceFromNoLatitude, AssertionError, "a distance from no latitude")
throws(degreePastPole, AssertionError, "a degree of longitude past the pole")

function distanceFromNoLatitude() {
  distanceMeters([0, Number.NaN], ORIGIN)
}

function degreePastPole() {
  metersPerDegreeLongitude(PAST_POLE_LATITUDE)
}

console.log("geodesy: every case holds")
