// Checks the geodesy module against values known by construction on the
// sphere of the mean radius: a degree of a meridian, a quarter of the
// equator, a degree across the antimeridian, and the bearings of the four
// compass directions, and against the bearing of a published example. It
// checks the tangent plane's scale bound over a city's span and past it,
// and that a position the module refuses is refused.

import {describe, expect, test} from "vitest"
import {IMPLEMENTATIONS} from "../implementations.mjs"

// Far finer than a reported position, and coarser than the rounding of a
// sum of a few products of doubles.
const TOLERANCE_METERS = 1e-6
const TOLERANCE_DEGREES = 1e-9

const NORTH_DEGREES = 0
const EAST_DEGREES = 90
const SOUTH_DEGREES = 180
const WEST_DEGREES = 270
const TURN_DEGREES = 360
const HALVES_PER_WHOLE = 2
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

const DistanceKind = Object.freeze({degree: "degree", quarter: "quarter", half: "half", none: "none"})

const distanceCases = [
  {name: "one position", source: SEATTLE, target: SEATTLE, kind: DistanceKind.none},
  {name: "a degree of the prime meridian", source: ORIGIN, target: ONE_NORTH, kind: DistanceKind.degree},
  {name: "a degree of the equator", source: ORIGIN, target: ONE_EAST, kind: DistanceKind.degree},
  {name: "a quarter of the equator", source: ORIGIN, target: QUARTER_EAST, kind: DistanceKind.quarter},
  {name: "a pole from the equator", source: EQUATOR_UNDER_SEATTLE, target: POLE_OVER_SEATTLE, kind: DistanceKind.quarter},
  {name: "a degree across the antimeridian", source: WEST_OF_ANTIMERIDIAN, target: EAST_OF_ANTIMERIDIAN, kind: DistanceKind.degree},
  {name: "antipodes", source: ORIGIN, target: ANTIPODE, kind: DistanceKind.half}
]

const bearingCases = [
  {name: "due north", source: SEATTLE, target: NORTH_OF_SEATTLE, degrees: NORTH_DEGREES},
  {name: "due east along the equator", source: ORIGIN, target: ONE_EAST, degrees: EAST_DEGREES},
  {name: "due south", source: SEATTLE, target: SOUTH_OF_SEATTLE, degrees: SOUTH_DEGREES},
  {name: "due west along the equator", source: ORIGIN, target: ONE_WEST, degrees: WEST_DEGREES},
  {name: "east across the antimeridian", source: WEST_OF_ANTIMERIDIAN, target: EAST_OF_ANTIMERIDIAN, degrees: EAST_DEGREES},
  {name: "one position", source: SEATTLE, target: SEATTLE, degrees: NORTH_DEGREES}
]

const refusedPositions = [
  {name: "a pair of no length", position: []},
  {name: "a longitude past 180", position: positionOf(places.pastLongitude)},
  {name: "a latitude past 90", position: positionOf(places.pastLatitude)},
  {name: "a latitude that is no number", position: [0, Number.NaN]},
  {name: "an object", position: {lon: 0, lat: 0}}
]

// The meters a distance case expects, from the module's own radius.
function expectedMeters({geodesy, kind}) {
  const halfEquatorMeters = Math.PI * geodesy.EARTH_RADIUS_METERS

  switch (kind) {
    case DistanceKind.none:
      return 0
    case DistanceKind.degree:
      return geodesy.METERS_PER_DEGREE
    case DistanceKind.quarter:
      return halfEquatorMeters / HALVES_PER_WHOLE
    case DistanceKind.half:
      return halfEquatorMeters
    default:
      throw new Error(`geodesy test: no distance kind ${kind}`)
  }
}

describe.each(IMPLEMENTATIONS)("geodesy ($name)", ({AssertionError, geodesy}) => {
  test.each(distanceCases)("distance: $name", ({source, target, kind}) => {
    const meters = expectedMeters({geodesy, kind})
    expect(Math.abs(geodesy.distanceMeters(source, target) - meters)).toBeLessThanOrEqual(TOLERANCE_METERS)
  })

  // A distance is the same either way.
  test("distance: Tacoma and Seattle either way", () => {
    expect(geodesy.distanceMeters(TACOMA, SEATTLE)).toBe(geodesy.distanceMeters(SEATTLE, TACOMA))
  })

  // A degree of longitude shortens with the cosine of the latitude.
  test("a degree of longitude at the equator", () => {
    const meters = geodesy.metersPerDegreeLongitude(0)
    expect(Math.abs(meters - geodesy.METERS_PER_DEGREE)).toBeLessThanOrEqual(TOLERANCE_METERS)
  })

  test("a degree of longitude at 60°", () => {
    const meters = geodesy.metersPerDegreeLongitude(SIXTY_DEGREES)
    const sixtyExpected = geodesy.METERS_PER_DEGREE * COSINE_OF_SIXTY_DEGREES
    expect(Math.abs(meters - sixtyExpected)).toBeLessThanOrEqual(TOLERANCE_METERS)
  })

  test.each(bearingCases)("bearing: $name", ({source, target, degrees}) => {
    expect(Math.abs(geodesy.initialBearingDegrees(source, target) - degrees)).toBeLessThanOrEqual(TOLERANCE_DEGREES)
  })

  test("bearing: Baghdad to Osaka", () => {
    const baghdadToOsaka = geodesy.initialBearingDegrees(BAGHDAD, OSAKA)
    expect(Math.round(baghdadToOsaka)).toBe(BAGHDAD_TO_OSAKA_DEGREES)
  })

  // A bearing is 0 or more and below a whole turn.
  test("bearing: north-west lies between west and a whole turn", () => {
    const northWest = geodesy.initialBearingDegrees(SEATTLE, NORTH_WEST_OF_SEATTLE)
    expect(northWest).toBeGreaterThan(WEST_DEGREES)
    expect(northWest).toBeLessThan(TURN_DEGREES)
  })

  test.each(refusedPositions)("refused position: $name", ({name, position}) => {
    expect(() => geodesy.assertPosition(position, name)).toThrow(AssertionError)
  })

  // A plane tangent at Seattle covers the half degree around it, a city's
  // span, and not the latitude of Vancouver or of Portland, at whose edges a
  // plane at Seattle's latitude is more than 2% off; a plane by the equator
  // covers a span across it, and a plane by the pole covers no span.
  test("Seattle's plane", () => {
    const seattlePlane = geodesy.tangentPlane({referenceLatitudeDegrees: SEATTLE[1]})
    expect(seattlePlane.metersPerDegreeLon).toBe(geodesy.metersPerDegreeLongitude(SEATTLE[1]))
  })

  const coveredSpans = [
    {name: "Seattle's plane over the city", referenceLatitudeDegrees: SEATTLE[1], latitudeDegreesMin: 47.35, latitudeDegreesMax: 47.85},
    {name: "a plane by the equator across it", referenceLatitudeDegrees: 0.5, latitudeDegreesMin: -0.5, latitudeDegreesMax: 1}
  ]

  test.each(coveredSpans)("covered span: $name", ({referenceLatitudeDegrees, latitudeDegreesMin, latitudeDegreesMax}) => {
    const plane = geodesy.tangentPlane({referenceLatitudeDegrees})
    expect(() => geodesy.assertPlaneCovers({plane, latitudeDegreesMin, latitudeDegreesMax})).not.toThrow()
  })

  const refusedSpans = [
    {name: "Seattle's plane at Vancouver", referenceLatitudeDegrees: SEATTLE[1], latitudeDegreesMin: 47.35, latitudeDegreesMax: 49.3},
    {name: "Seattle's plane at Portland", referenceLatitudeDegrees: SEATTLE[1], latitudeDegreesMin: 45.5, latitudeDegreesMax: 47.85},
    {name: "latitudes out of order", referenceLatitudeDegrees: SEATTLE[1], latitudeDegreesMin: 48, latitudeDegreesMax: 47},
    {name: "a plane by the pole", referenceLatitudeDegrees: 89.9, latitudeDegreesMin: 89.8, latitudeDegreesMax: 89.9}
  ]

  test.each(refusedSpans)("refused span: $name", ({referenceLatitudeDegrees, latitudeDegreesMin, latitudeDegreesMax}) => {
    const plane = geodesy.tangentPlane({referenceLatitudeDegrees})
    expect(() => geodesy.assertPlaneCovers({plane, latitudeDegreesMin, latitudeDegreesMax})).toThrow(AssertionError)
  })

  test("a distance from no latitude", () => {
    expect(() => geodesy.distanceMeters([0, Number.NaN], ORIGIN)).toThrow(AssertionError)
  })

  test("a degree of longitude past the pole", () => {
    expect(() => geodesy.metersPerDegreeLongitude(PAST_POLE_LATITUDE)).toThrow(AssertionError)
  })
})
