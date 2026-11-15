// Checks the geodesy module against the shared math cases: values known by
// construction on the sphere of the mean radius, a degree of a meridian, a
// quarter of the equator, a degree across the antimeridian, and the bearings
// of the four compass directions, and the bearing of a published example. It
// checks the tangent plane's scale bound over a city's span and past it, and
// that a position the module refuses is refused.

import {describe, expect, test} from "vitest"
import {fixtureJson, fixtureNumber} from "../fixtures.mjs"
import {implementationsWith} from "../implementations.mjs"

const cases = await fixtureJson("math/geodesy.json")
const TOLERANCE_METERS = cases.toleranceMeters
const TOLERANCE_DEGREES = cases.toleranceDegrees
const HALVES_PER_WHOLE = 2

const DistanceKind = Object.freeze({degree: "degree", quarter: "quarter", half: "half", none: "none"})

// A position as an argument holds an array; a value no array is refused
// through JavaScript's types alone, so its case lives here rather than in the
// shared fixture, whose Rust cases take coordinates as doubles.
const refusedObject = {name: "an object", position: {lon: 0, lat: 0}}

function place(name) {
  return cases.places[name]
}

function coordinatesOf(position) {
  return Array.from(position, fixtureNumber)
}

function refusedPositions() {
  const refused = []
  for (const {name, position} of cases.refusedPositions) {
    refused.push({name, position: coordinatesOf(position)})
  }
  refused.push(refusedObject)
  return refused
}

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

describe.each(implementationsWith("geodesy"))("geodesy ($name)", ({AssertionError, geodesy}) => {
  test.each(cases.distances)("distance: $name", ({source, target, kind}) => {
    const meters = expectedMeters({geodesy, kind})
    const distance = geodesy.distanceMeters(place(source), place(target))
    expect(Math.abs(distance - meters)).toBeLessThanOrEqual(TOLERANCE_METERS)
  })

  test.each(cases.symmetricDistances)("distance: $name", ({source, target}) => {
    const forward = geodesy.distanceMeters(place(source), place(target))
    const backward = geodesy.distanceMeters(place(target), place(source))
    expect(backward).toBe(forward)
  })

  // A degree of longitude shortens with the cosine of the latitude.
  test.each(cases.longitudeDegrees)("$name", ({latitudeDegrees, share}) => {
    const meters = geodesy.metersPerDegreeLongitude(latitudeDegrees)
    const expected = geodesy.METERS_PER_DEGREE * share
    expect(Math.abs(meters - expected)).toBeLessThanOrEqual(TOLERANCE_METERS)
  })

  test.each(cases.bearings)("bearing: $name", ({source, target, degrees}) => {
    const bearing = geodesy.initialBearingDegrees(place(source), place(target))
    expect(Math.abs(bearing - degrees)).toBeLessThanOrEqual(TOLERANCE_DEGREES)
  })

  test.each(cases.roundedBearings)("bearing: $name", ({source, target, degrees}) => {
    const bearing = geodesy.initialBearingDegrees(place(source), place(target))
    expect(Math.round(bearing)).toBe(degrees)
  })

  // A bearing is 0 or more and below a whole turn.
  test.each(cases.bearingRanges)("bearing: $name", ({source, target, above, below}) => {
    const bearing = geodesy.initialBearingDegrees(place(source), place(target))
    expect(bearing).toBeGreaterThan(above)
    expect(bearing).toBeLessThan(below)
  })

  test.each(refusedPositions())("refused position: $name", ({name, position}) => {
    expect(() => geodesy.assertPosition(position, name)).toThrow(AssertionError)
  })

  test.each(cases.planes)("$name", ({referenceLatitudeDegrees}) => {
    const plane = geodesy.tangentPlane({referenceLatitudeDegrees})
    expect(plane.metersPerDegreeLon).toBe(geodesy.metersPerDegreeLongitude(referenceLatitudeDegrees))
  })

  // A plane tangent at Seattle covers the half degree around it, a city's
  // span, and not the latitude of Vancouver or of Portland, at whose edges a
  // plane at Seattle's latitude is more than 2% off; a plane by the equator
  // covers a span across it, and a plane by the pole covers no span.
  test.each(cases.coveredSpans)("covered span: $name", ({referenceLatitudeDegrees, latitudeDegreesMin, latitudeDegreesMax}) => {
    const plane = geodesy.tangentPlane({referenceLatitudeDegrees})
    expect(() => geodesy.assertPlaneCovers({plane, latitudeDegreesMin, latitudeDegreesMax})).not.toThrow()
  })

  test.each(cases.refusedSpans)("refused span: $name", ({referenceLatitudeDegrees, latitudeDegreesMin, latitudeDegreesMax}) => {
    const plane = geodesy.tangentPlane({referenceLatitudeDegrees})
    expect(() => geodesy.assertPlaneCovers({plane, latitudeDegreesMin, latitudeDegreesMax})).toThrow(AssertionError)
  })

  test.each(cases.refusedDistances)("refused: $name", ({source, target}) => {
    const sourceCoordinates = coordinatesOf(source)
    const targetCoordinates = coordinatesOf(target)
    expect(() => geodesy.distanceMeters(sourceCoordinates, targetCoordinates)).toThrow(AssertionError)
  })

  test.each(cases.refusedLongitudeDegrees)("refused: $name", ({latitudeDegrees}) => {
    expect(() => geodesy.metersPerDegreeLongitude(latitudeDegrees)).toThrow(AssertionError)
  })
})
