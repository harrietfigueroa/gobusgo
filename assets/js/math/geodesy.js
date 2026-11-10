// Distances and directions on the Earth, taken as a sphere of the mean
// radius. Everything here is pure. A position is [lon, lat] in degrees,
// the order of GeoJSON and MapLibre.
//
// A distance on the sphere is within 0.5% of one on the ellipsoid.

import {assertCondition} from "../assert.js"
import {DEGREES_PER_HALF_TURN, degrees, normalizedDegrees, radians} from "./angles.js"
import {assertOrdered} from "./checks.js"

/**
 * The mean radius of the Earth, IUGG's R1 of 6,371,008.7714 m for the
 * GRS 80 ellipsoid rounded to the decimeter.
 * https://en.wikipedia.org/wiki/Earth_radius#Arithmetic_mean_radius — checked 2026-11-09
 */
export const EARTH_RADIUS_METERS = 6371008.8

/** The meters of a degree of latitude, and of a degree of longitude at the equator. */
export const METERS_PER_DEGREE = Math.PI * EARTH_RADIUS_METERS / DEGREES_PER_HALF_TURN

/** The index of a position's longitude. */
export const LON = 0

/** The index of a position's latitude. */
export const LAT = 1

const LONGITUDE_DEGREES_MAX = 180
const LATITUDE_DEGREES_MAX = 90
const COORDINATE_COUNT = 2
const HALF = 2

/** Asserts that `position` is [lon, lat] in degrees; `message` names it in a failure. */
export function assertPosition(position, message) {
  assertCondition(Array.isArray(position), `${message}: a position is [lon, lat]`)
  assertCondition(position.length === COORDINATE_COUNT, `${message}: a position has two coordinates, not ${position.length}`)
  const [lon, lat] = position
  assertCondition(Number.isFinite(lon), `${message}: longitude ${lon} is not a number`)
  assertCondition(Number.isFinite(lat), `${message}: latitude ${lat} is not a number`)
  assertCondition(Math.abs(lon) <= LONGITUDE_DEGREES_MAX, `${message}: longitude ${lon} is out of range`)
  assertCondition(Math.abs(lat) <= LATITUDE_DEGREES_MAX, `${message}: latitude ${lat} is out of range`)
}

/**
 * The great-circle distance in meters between the positions `source` and
 * `target`, by the haversine formula, which keeps its precision at the
 * short distances a city holds. A pair across the antimeridian is
 * measured the short way round.
 */
export function distanceMeters(source, target) {
  const [sourceLon, sourceLat] = source
  const [targetLon, targetLat] = target
  const latDelta = radians(targetLat - sourceLat)
  const lonDelta = radians(targetLon - sourceLon)
  const sinLat = Math.sin(latDelta / HALF)
  const sinLon = Math.sin(lonDelta / HALF)
  const chord = sinLat * sinLat + Math.cos(radians(sourceLat)) * Math.cos(radians(targetLat)) * sinLon * sinLon
  // The haversine sum can round past 1 for antipodal positions, where arcsine has no value.
  const halfAngleSine = Math.min(1, Math.sqrt(chord))
  const meters = HALF * EARTH_RADIUS_METERS * Math.asin(halfAngleSine)
  assertOrdered({low: 0, high: meters, label: "geodesy: a distance in meters"})
  return meters
}

/**
 * The initial great-circle bearing from `source` to `target`, in degrees
 * clockwise from true north, from 0 up to 360; 0 where the two are one
 * position.
 */
export function initialBearingDegrees(source, target) {
  const [sourceLon, sourceLat] = source
  const [targetLon, targetLat] = target
  const sourceLatRadians = radians(sourceLat)
  const targetLatRadians = radians(targetLat)
  const lonDelta = radians(targetLon - sourceLon)
  const east = Math.sin(lonDelta) * Math.cos(targetLatRadians)
  const northSource = Math.cos(sourceLatRadians) * Math.sin(targetLatRadians)
  const northTarget = Math.sin(sourceLatRadians) * Math.cos(targetLatRadians) * Math.cos(lonDelta)
  const north = northSource - northTarget
  const bearing = degrees(Math.atan2(east, north))
  return normalizedDegrees(bearing)
}

/**
 * The meters of a degree of longitude at `latitudeDegrees`. Multiplying a
 * longitude by it, and a latitude by `METERS_PER_DEGREE`, places positions
 * on a plane tangent at that latitude, which is meaningless across the
 * antimeridian.
 */
export function metersPerDegreeLongitude(latitudeDegrees) {
  assertCondition(Math.abs(latitudeDegrees) <= LATITUDE_DEGREES_MAX, `geodesy: latitude ${latitudeDegrees} is out of range`)
  return METERS_PER_DEGREE * Math.cos(radians(latitudeDegrees))
}

/**
 * The most a tangent plane's longitude scale may be off at a latitude it
 * covers, as a share of the true scale: 2% of an east-west offset of 100 m
 * is 2 m, finer than a reported vehicle position.
 */
export const PLANE_SCALE_ERROR_MAX = 0.02

/**
 * A plane tangent at `referenceLatitudeDegrees`, taken from the data it
 * measures, such as a path's first point or the center of a map's bounds:
 * the meters of a degree of longitude on it.
 */
export function tangentPlane({referenceLatitudeDegrees}) {
  const metersPerDegreeLon = metersPerDegreeLongitude(referenceLatitudeDegrees)
  assertCondition(metersPerDegreeLon > 0, `geodesy: a plane at ${referenceLatitudeDegrees} has a scale of ${metersPerDegreeLon}`)
  return Object.freeze({referenceLatitudeDegrees, metersPerDegreeLon})
}

function scaleError({plane, latitudeDegrees}) {
  const trueMetersPerDegreeLon = metersPerDegreeLongitude(latitudeDegrees)
  return Math.abs(plane.metersPerDegreeLon / trueMetersPerDegreeLon - 1)
}

/**
 * Asserts that `plane` measures every latitude from `latitudeDegreesMin` to
 * `latitudeDegreesMax` within `PLANE_SCALE_ERROR_MAX`, so data that spans
 * too much of the globe for one plane fails here rather than drifting.
 */
export function assertPlaneCovers({plane, latitudeDegreesMin, latitudeDegreesMax}) {
  assertCondition(latitudeDegreesMin <= latitudeDegreesMax, `geodesy: latitudes ${latitudeDegreesMin} to ${latitudeDegreesMax} are out of order`)
  const southError = scaleError({plane, latitudeDegrees: latitudeDegreesMin})
  const northError = scaleError({plane, latitudeDegrees: latitudeDegreesMax})
  assertCondition(southError <= PLANE_SCALE_ERROR_MAX, `geodesy: the plane at ${plane.referenceLatitudeDegrees} is ${southError} off at ${latitudeDegreesMin}`)
  assertCondition(northError <= PLANE_SCALE_ERROR_MAX, `geodesy: the plane at ${plane.referenceLatitudeDegrees} is ${northError} off at ${latitudeDegreesMax}`)

  // A span across the equator is widest there, between its two ends.
  const isAcrossEquator = latitudeDegreesMin < 0 && latitudeDegreesMax > 0
  if (isAcrossEquator) {
    const equatorError = scaleError({plane, latitudeDegrees: 0})
    assertCondition(equatorError <= PLANE_SCALE_ERROR_MAX, `geodesy: the plane at ${plane.referenceLatitudeDegrees} is ${equatorError} off at the equator`)
  }
}
