// Cuts the vehicle prediction check's fixture from a store of raw
// OneBusAway responses: one agency's `vehicles-for-agency` fetches of one
// UTC day, a seeded sample of their vehicles, and the path of each trip a
// measured report is on, built from the newest stored `schedule-for-route`
// and `stops-for-route` responses of any day. The output
// holds positions, times, trip identifiers, and paths: no response's
// metadata, request, or address. Run it with
//
//   node test/scripts/vehicle_prediction_fixture.mjs --store data/raw/oba \
//     --date 2026-11-08 --agency 1 --out test/fixtures/vehicle_prediction/kcm_2026-11-08.json.gz
//
// and `--vehicles all` to cut every vehicle of the day instead of the sample.

import {readFileSync, readdirSync, writeFileSync} from "node:fs"
import {join} from "node:path"
import {gunzipSync, gzipSync} from "node:zlib"
import {assertCondition} from "../../assets/js/core/assert.js"
import {METERS_PER_DEGREE, distanceMeters, metersPerDegreeLongitude} from "../../assets/js/core/math/geodesy.js"
import {clamp, lerp} from "../../assets/js/core/math/interpolation.js"
import {segmentIndexAt} from "../../assets/js/core/math/polyline.js"

// The sample: this many vehicles, shuffled by this seed.
const SAMPLE_VEHICLE_COUNT = 60
const SAMPLE_SEED = 317
const ALL_VEHICLES = "all"

// A pair is measured when the later report comes at most this long after
// the one the fetch held, and is left out when it lies farther than the
// second bound from it, a report that jumped across the map.
const PAIR_HORIZON_MS_MAX = 5 * 60 * 1000
const PAIR_JUMP_METERS_MAX = 5000

// The path builder: a stop pair follows a route polyline that passes within
// this distance of both stops, no longer than the straight distance times
// the factor plus the slack, and a straight line otherwise.
const STOP_SNAP_METERS = 45
const PATH_STRETCH_FACTOR = 2.5
const PATH_STRETCH_SLACK_METERS = 150
const PROJECTION_SLACK_METERS = 1

// The builder measures on a plane tangent at Seattle's latitude.
const PLANE_LATITUDE = 47.6
const METERS_PER_DEGREE_LON = metersPerDegreeLongitude(PLANE_LATITUDE)

// A service date is the local midnight its trips count from; noon after it
// is on the service date in UTC as in Seattle.
const SERVICE_DATE_NOON_MS = 12 * 60 * 60 * 1000
const ISO_DATE_LENGTH = 10

const FILE_COUNT_MAX = 20000
const POSITION_DECIMALS = 6
const POLYLINE_DECIMALS = 5
const POLYLINE_PRECISION = 1e5
const POLYLINE_CHUNK_BITS = 5
const POLYLINE_CHUNK_MASK = 0x1f
const POLYLINE_CONTINUE = 0x20
const POLYLINE_OFFSET = 63
const DISTANCE_DECIMALS = 1
const GZIP_LEVEL = 9
const UINT32_RANGE = 0x100000000
const HALF = 2
const FLAG_WITH_VALUE = 2
const FLAG_PREFIX = "--"
const ARGUMENT_START = 2
const STOP_COUNT_MIN = 2
const LAST_SEGMENT_OFFSET = 2
const NO_FETCH_INDEX = -1
const MULBERRY_INCREMENT = 0x6d2b79f5
const MULBERRY_SHIFT_FIRST = 15
const MULBERRY_SHIFT_SECOND = 7
const MULBERRY_SHIFT_THIRD = 14
const MULBERRY_ONE = 1
const MULBERRY_SIXTY_ONE = 61

const SOURCE = "King County Metro vehicles-for-agency fetches stored on the date this fixture is named for, a seeded sample of vehicles; paths built from the stored schedules and route paths"

function argumentsOf(argv) {
  const values = new Map()
  for (let index = 0; index + 1 < argv.length; index += FLAG_WITH_VALUE) {
    const flag = argv[index]
    assertCondition(flag.startsWith(FLAG_PREFIX), `expected a flag, not ${flag}`)
    values.set(flag.slice(FLAG_PREFIX.length), argv[index + 1])
  }
  for (const name of ["store", "date", "agency", "out"]) {
    assertCondition(values.has(name), `--${name} is required`)
  }
  return values
}

function readStored(path) {
  const bytes = readFileSync(path)
  const text = gunzipSync(bytes).toString("utf8")
  return JSON.parse(text)
}

function namesIn(directory) {
  try {
    return readdirSync(directory)
  } catch (error) {
    // A dataset, route, or date the store never fetched has no directory.
    if (error.code === "ENOENT") {
      return []
    }
    throw error
  }
}

function sortedEntries(directory) {
  const names = namesIn(directory)
  assertCondition(names.length <= FILE_COUNT_MAX, `${directory} holds ${names.length} entries`)
  // A copy, since `sort` orders the array in place.
  return Array.from(names).sort()
}

// The newest stored response under any of `datasetDirectory`'s date
// partitions, within the partition path `within`, or none.
function newestStored({datasetDirectory, within}) {
  const datePartitions = sortedEntries(datasetDirectory)
  let newest = {kind: "none"}
  for (const partition of datePartitions) {
    const directory = join(datasetDirectory, partition, within)
    const files = sortedEntries(directory)
    if (files.length > 0) {
      newest = {kind: "found", path: join(directory, files[files.length - 1])}
    }
  }
  return newest
}

function planeOf([lat, lon]) {
  return [lon * METERS_PER_DEGREE_LON, lat * METERS_PER_DEGREE]
}

function latLonOf([x, y]) {
  return [y / METERS_PER_DEGREE, x / METERS_PER_DEGREE_LON]
}

function havMeters(source, target) {
  return distanceMeters([source[1], source[0]], [target[1], target[0]])
}

// A line on the plane, from [lat, lon] points, with each point's distance
// along it.
function lineOf(points) {
  const planePoints = Array.from(points, planeOf)
  const cumulative = [0]
  for (let index = 1; index < planePoints.length; index++) {
    const step = Math.hypot(planePoints[index][0] - planePoints[index - 1][0], planePoints[index][1] - planePoints[index - 1][1])
    cumulative.push(cumulative[index - 1] + step)
  }
  return {points: planePoints, cumulative, length: cumulative[cumulative.length - 1]}
}

// The nearest point of `line` to `position` at or after `alongMin`, as its
// distance from the position and its distance along the line. A point's
// distance along its segment is the square root of the segment's squared
// length, the measure the fixture is cut with, which differs in the last
// bit from a share of the cumulative distances.
function projectOnLine({line, position, alongMin}) {
  const [x, y] = planeOf(position)
  const floor = alongMin - PROJECTION_SLACK_METERS
  let best = {offset: Infinity, along: alongMin}
  for (let index = 0; index + 1 < line.points.length; index++) {
    if (line.cumulative[index + 1] < floor) {
      continue
    }
    const [sourceX, sourceY] = line.points[index]
    const deltaX = line.points[index + 1][0] - sourceX
    const deltaY = line.points[index + 1][1] - sourceY
    const squared = deltaX * deltaX + deltaY * deltaY
    let fraction = 0
    if (squared > 0) {
      const dot = (x - sourceX) * deltaX + (y - sourceY) * deltaY
      fraction = clamp({value: dot / squared, min: 0, max: 1})
    }
    const along = line.cumulative[index] + fraction * Math.sqrt(squared)
    const offset = Math.hypot(sourceX + fraction * deltaX - x, sourceY + fraction * deltaY - y)
    const isAfterFloor = along >= floor
    const isNearer = offset < best.offset
    const isBetter = isAfterFloor && isNearer
    if (isBetter) {
      best = {offset, along}
    }
  }
  return best
}

function pointAt({line, along}) {
  const clamped = clamp({value: along, min: 0, max: line.length})
  const index = segmentIndexAt({cumulative: line.cumulative, along: clamped})
  const span = line.cumulative[index + 1] - line.cumulative[index]
  let fraction = 0
  if (span > 0) {
    fraction = (clamped - line.cumulative[index]) / span
  }
  const [sourceX, sourceY] = line.points[index]
  const [targetX, targetY] = line.points[index + 1]
  return latLonOf([lerp({from: sourceX, to: targetX, fraction}), lerp({from: sourceY, to: targetY, fraction})])
}

// The stretch of `line` from `start` to `end` along it, as [lat, lon] points.
function stretchOf({line, start, end}) {
  const points = [pointAt({line, along: start})]
  for (let index = 0; index < line.points.length; index++) {
    const along = line.cumulative[index]
    const isInside = start < along && along < end
    if (isInside) {
      points.push(latLonOf(line.points[index]))
    }
  }
  points.push(pointAt({line, along: end}))
  return points
}

function decodePolyline(text) {
  const points = []
  const totals = [0, 0]
  let index = 0
  while (index < text.length) {
    for (let coordinate = 0; coordinate < totals.length; coordinate++) {
      let shift = 0
      let result = 0
      let chunk = POLYLINE_CONTINUE
      while (chunk >= POLYLINE_CONTINUE) {
        chunk = text.charCodeAt(index) - POLYLINE_OFFSET
        index++
        result |= (chunk & POLYLINE_CHUNK_MASK) << shift
        shift += POLYLINE_CHUNK_BITS
      }
      let delta = result >> 1
      if (result & 1) {
        delta = ~delta
      }
      totals[coordinate] += delta
    }
    points.push([totals[0] / POLYLINE_PRECISION, totals[1] / POLYLINE_PRECISION])
  }
  return points
}

function encodeValue(value) {
  let rest = value << 1
  if (value < 0) {
    rest = ~(value << 1)
  }
  let text = ""
  while (rest >= POLYLINE_CONTINUE) {
    text += String.fromCharCode((POLYLINE_CONTINUE | (rest & POLYLINE_CHUNK_MASK)) + POLYLINE_OFFSET)
    rest >>= POLYLINE_CHUNK_BITS
  }
  return text + String.fromCharCode(rest + POLYLINE_OFFSET)
}

// Google's encoded polyline format, latitude first, at five decimals.
// https://developers.google.com/maps/documentation/utilities/polylinealgorithm — checked 2026-11-09
function encodePolyline(points) {
  let text = ""
  let last = [0, 0]
  for (const [lat, lon] of points) {
    const scaled = [Math.round(lat * POLYLINE_PRECISION), Math.round(lon * POLYLINE_PRECISION)]
    text += encodeValue(scaled[0] - last[0]) + encodeValue(scaled[1] - last[1])
    last = scaled
  }
  return text
}

function rounded({value, decimals}) {
  return Number(value.toFixed(decimals))
}

function serviceDateText(serviceDateMs) {
  const noon = new Date(serviceDateMs + SERVICE_DATE_NOON_MS)
  return noon.toISOString().slice(0, ISO_DATE_LENGTH)
}

function routeLinesOf(entry) {
  const encoded = []
  for (const polyline of entry.polylines) {
    encoded.push(polyline.points)
  }
  for (const grouping of entry.stopGroupings) {
    for (const group of grouping.stopGroups) {
      for (const polyline of group.polylines) {
        encoded.push(polyline.points)
      }
    }
  }
  const lines = []
  for (const text of encoded) {
    const points = decodePolyline(text)
    if (points.length > 1) {
      lines.push(lineOf(points))
    }
  }
  return lines
}

function storeReaderOf(store) {
  const routes = new Map()
  const schedules = new Map()

  function routeOf(routeId) {
    if (!routes.has(routeId)) {
      const stored = newestStored({datasetDirectory: join(store, "stops-for-route"), within: `route=${routeId}`})
      let route = {kind: "none"}
      if (stored.kind === "found") {
        const {data} = readStored(stored.path).body
        const stops = new Map()
        for (const stop of data.references.stops) {
          stops.set(stop.id, [stop.lat, stop.lon])
        }
        route = {kind: "found", lines: routeLinesOf(data.entry), stops}
      }
      routes.set(routeId, route)
    }
    return routes.get(routeId)
  }

  function stopTimesOf({routeId, serviceDateMs, tripId}) {
    const key = `${routeId}@${serviceDateMs}`
    if (!schedules.has(key)) {
      const within = join(`route=${routeId}`, `service-date=${serviceDateText(serviceDateMs)}`)
      const stored = newestStored({datasetDirectory: join(store, "schedule-for-route"), within})
      const trips = new Map()
      if (stored.kind === "found") {
        for (const grouping of readStored(stored.path).body.data.entry.stopTripGroupings) {
          for (const trip of grouping.tripsWithStopTimes) {
            trips.set(trip.tripId, trip.stopTimes)
          }
        }
      }
      schedules.set(key, trips)
    }
    const trips = schedules.get(key)
    if (!trips.has(tripId)) {
      return {kind: "none"}
    }
    return {kind: "found", stopTimes: trips.get(tripId)}
  }

  return {routeOf, stopTimesOf}
}

// The stretch of a route polyline between two stops: the shortest that
// passes near both, in order, and is not much longer than the straight line.
function stopPairStretch({lines, source, target}) {
  const direct = havMeters(source, target)
  const lengthMax = PATH_STRETCH_FACTOR * direct + PATH_STRETCH_SLACK_METERS
  let best = {kind: "none"}
  for (const line of lines) {
    const fromSource = projectOnLine({line, position: source, alongMin: -Infinity})
    const fromTarget = projectOnLine({line, position: target, alongMin: -Infinity})
    const isNearSource = fromSource.offset < STOP_SNAP_METERS
    const isNearTarget = fromTarget.offset < STOP_SNAP_METERS
    const isNearBoth = isNearSource && isNearTarget
    const isForward = fromTarget.along > fromSource.along
    const isNearForward = isNearBoth && isForward
    const stretch = fromTarget.along - fromSource.along
    const isShortEnough = stretch < lengthMax
    const fits = isNearForward && isShortEnough
    const isShortest = best.kind === "none" || stretch < best.stretch
    const isBest = fits && isShortest
    if (isBest) {
      best = {kind: "found", line, start: fromSource.along, end: fromTarget.along, stretch}
    }
  }
  if (best.kind === "none") {
    return [source, target]
  }
  return stretchOf(best)
}

// A trip's path in the fixture's form: the encoded polyline of its points
// at five decimals, and each stop's great-circle distance along those
// decoded points with its scheduled times.
function pathEntryOf({line, stopAlongs, stopTimes}) {
  const points = []
  for (const planePoint of line.points) {
    const [lat, lon] = latLonOf(planePoint)
    points.push([rounded({value: lat, decimals: POLYLINE_DECIMALS}), rounded({value: lon, decimals: POLYLINE_DECIMALS})])
  }
  const cumulative = [0]
  for (let index = 1; index < points.length; index++) {
    cumulative.push(cumulative[index - 1] + havMeters(points[index - 1], points[index]))
  }

  const stops = []
  let floor = 0
  for (let index = 0; index < stopAlongs.length; index++) {
    const along = stopAlongs[index]
    const segmentLast = line.cumulative.length - LAST_SEGMENT_OFFSET
    const segment = Math.min(segmentLast, segmentIndexAt({cumulative: line.cumulative, along}))
    const span = line.cumulative[segment + 1] - line.cumulative[segment]
    let fraction = 0
    if (span > 0) {
      fraction = clamp({value: (along - line.cumulative[segment]) / span, min: 0, max: 1})
    }
    const meters = lerp({from: cumulative[segment], to: cumulative[segment + 1], fraction})
    floor = Math.max(floor, meters)
    const {arrivalTime, departureTime} = stopTimes[index]
    stops.push([rounded({value: floor, decimals: DISTANCE_DECIMALS}), arrivalTime, departureTime])
  }
  return {points: encodePolyline(points), stops}
}

function tripPathOf({reader, routeId, serviceDateMs, tripId}) {
  const route = reader.routeOf(routeId)
  const schedule = reader.stopTimesOf({routeId, serviceDateMs, tripId})
  const isKnown = route.kind === "found" && schedule.kind === "found"
  if (!isKnown) {
    return {kind: "none"}
  }
  const {stopTimes} = schedule
  for (const stopTime of stopTimes) {
    if (!route.stops.has(stopTime.stopId)) {
      return {kind: "none"}
    }
  }
  if (stopTimes.length < STOP_COUNT_MIN) {
    return {kind: "none"}
  }

  const points = []
  for (let index = 0; index + 1 < stopTimes.length; index++) {
    const source = route.stops.get(stopTimes[index].stopId)
    const target = route.stops.get(stopTimes[index + 1].stopId)
    const stretch = stopPairStretch({lines: route.lines, source, target})
    let first = 1
    if (points.length === 0) {
      first = 0
    }
    for (let point = first; point < stretch.length; point++) {
      points.push(stretch[point])
    }
  }

  const line = lineOf(points)
  const stopAlongs = []
  let alongMin = 0
  for (const stopTime of stopTimes) {
    const projection = projectOnLine({line, position: route.stops.get(stopTime.stopId), alongMin})
    stopAlongs.push(projection.along)
    alongMin = projection.along
  }
  return {kind: "found", entry: pathEntryOf({line, stopAlongs, stopTimes})}
}

// One agency's reported vehicles of every fetch, oldest fetch first.
function fetchesOf({store, date, agency}) {
  const directory = join(store, "vehicles-for-agency", `dt=${date}`, `agency=${agency}`)
  const fetches = new Map()
  for (const name of sortedEntries(directory)) {
    const {body} = readStored(join(directory, name))
    if (fetches.has(body.currentTime)) {
      continue
    }
    const routes = new Map()
    for (const trip of body.data.references.trips) {
      routes.set(trip.id, trip.routeId)
    }
    const vehicles = new Map()
    for (const vehicle of body.data.list) {
      const status = vehicle.tripStatus
      const hasStatus = typeof status === "object" && status !== null
      const isPredicted = hasStatus && status.predicted === true
      const isLocated = vehicle.location !== undefined && vehicle.lastLocationUpdateTime > 0
      const isReported = isPredicted && isLocated
      if (!isReported) {
        continue
      }
      vehicles.set(vehicle.vehicleId, {
        reportedAtMs: vehicle.lastLocationUpdateTime,
        report: [vehicle.location.lat, vehicle.location.lon],
        position: [status.position.lat, status.position.lon],
        tripId: status.activeTripId,
        routeId: routes.get(status.activeTripId),
        serviceDateMs: status.serviceDate
      })
    }
    fetches.set(body.currentTime, vehicles)
  }
  return Array.from(fetches.entries()).sort(byFetchTime)
}

function byFetchTime(left, right) {
  return left[0] - right[0]
}

function byNumber(left, right) {
  return left - right
}

// Each vehicle's reports by time, each from the first fetch that held it.
function reportsByVehicle(fetches) {
  const reports = new Map()
  for (const [fetchedAtMs, vehicles] of fetches) {
    for (const [vehicleId, vehicle] of vehicles) {
      if (!reports.has(vehicleId)) {
        reports.set(vehicleId, new Map())
      }
      const byTime = reports.get(vehicleId)
      if (!byTime.has(vehicle.reportedAtMs)) {
        byTime.set(vehicle.reportedAtMs, {...vehicle, fetchedAtMs})
      }
    }
  }
  return reports
}

// The index of the newest fetch at or before `atMs`, or -1.
function newestFetchIndex({fetchTimes, atMs}) {
  let low = NO_FETCH_INDEX
  let high = fetchTimes.length
  while (high - low > 1) {
    const middle = Math.floor((low + high) / HALF)
    if (fetchTimes[middle] <= atMs) {
      low = middle
    } else {
      high = middle
    }
  }
  return low
}

// A pseudo-random sequence in [0, 1) from a 32-bit seed: mulberry32, so the
// sample is the same on every machine and every run.
function randomOf(seed) {
  let state = seed
  return function nextRandom() {
    state = (state + MULBERRY_INCREMENT) | 0
    let mixed = Math.imul(state ^ (state >>> MULBERRY_SHIFT_FIRST), MULBERRY_ONE | state)
    mixed = (mixed + Math.imul(mixed ^ (mixed >>> MULBERRY_SHIFT_SECOND), MULBERRY_SIXTY_ONE | mixed)) ^ mixed
    return ((mixed ^ (mixed >>> MULBERRY_SHIFT_THIRD)) >>> 0) / UINT32_RANGE
  }
}

function sampledVehicles({vehicleIds, count}) {
  // A copy, since `sort` orders the array in place.
  const shuffled = Array.from(vehicleIds).sort()
  const nextRandom = randomOf(SAMPLE_SEED)
  for (let index = shuffled.length - 1; index > 0; index--) {
    const other = Math.floor(nextRandom() * (index + 1))
    const kept = shuffled[index]
    shuffled[index] = shuffled[other]
    shuffled[other] = kept
  }
  const sample = shuffled.slice(0, count)
  return sample.sort()
}

function main() {
  const options = argumentsOf(process.argv.slice(ARGUMENT_START))
  const store = options.get("store")
  const date = options.get("date")
  const fetches = fetchesOf({store, date, agency: options.get("agency")})
  const fetchTimes = Array.from(fetches, firstOf)
  const reports = reportsByVehicle(fetches)
  let vehicleIds = Array.from(reports.keys()).sort()
  const sampleText = options.get("vehicles")
  if (sampleText !== ALL_VEHICLES) {
    let count = SAMPLE_VEHICLE_COUNT
    if (sampleText !== undefined) {
      count = Number(sampleText)
    }
    vehicleIds = sampledVehicles({vehicleIds, count})
  }

  const reader = storeReaderOf(store)
  const trips = []
  const tripIndexes = new Map()
  const paths = {}

  function tripIndexOf({tripId, serviceDateMs}) {
    const key = `${tripId}@${serviceDateMs}`
    if (!tripIndexes.has(key)) {
      tripIndexes.set(key, trips.length)
      trips.push([tripId, serviceDateMs])
    }
    return tripIndexes.get(key)
  }

  const cut = []
  let pairCount = 0
  for (const vehicleId of vehicleIds) {
    const byTime = reports.get(vehicleId)
    const times = Array.from(byTime.keys()).sort(byNumber)
    const pairs = []
    for (let truthIndex = 0; truthIndex < times.length; truthIndex++) {
      const truthAtMs = times[truthIndex]
      const fetchIndex = newestFetchIndex({fetchTimes, atMs: truthAtMs})
      if (fetchIndex < 0) {
        continue
      }
      const held = fetches[fetchIndex][1].get(vehicleId)
      const isHeldEarlier = held !== undefined && held.reportedAtMs < truthAtMs
      if (!isHeldEarlier) {
        continue
      }
      const truth = byTime.get(truthAtMs)
      const isWithinHorizon = truthAtMs - held.reportedAtMs <= PAIR_HORIZON_MS_MAX
      const isNear = havMeters(held.report, truth.report) <= PAIR_JUMP_METERS_MAX
      const isMeasured = isWithinHorizon && isNear
      if (!isMeasured) {
        continue
      }
      const tripIndex = tripIndexOf(held)
      pairs.push([
        times.indexOf(held.reportedAtMs),
        truthIndex,
        rounded({value: held.position[1], decimals: POSITION_DECIMALS}),
        rounded({value: held.position[0], decimals: POSITION_DECIMALS}),
        tripIndex
      ])
      const isNewPath = held.routeId !== undefined && !Object.hasOwn(paths, String(tripIndex))
      if (isNewPath) {
        const path = tripPathOf({reader, routeId: held.routeId, serviceDateMs: held.serviceDateMs, tripId: held.tripId})
        if (path.kind === "found") {
          paths[String(tripIndex)] = path.entry
        }
      }
    }
    pairCount += pairs.length
    cut.push({vehicleId, times, pairs})
  }

  let baseMs = Infinity
  for (const {times} of cut) {
    baseMs = Math.min(baseMs, times[0])
  }
  const vehicles = []
  for (const {vehicleId, times, pairs} of cut) {
    const byTime = reports.get(vehicleId)
    const entries = []
    for (const atMs of times) {
      const report = byTime.get(atMs)
      entries.push([
        atMs - baseMs,
        rounded({value: report.report[1], decimals: POSITION_DECIMALS}),
        rounded({value: report.report[0], decimals: POSITION_DECIMALS}),
        tripIndexOf(report),
        report.fetchedAtMs - atMs
      ])
    }
    vehicles.push({reports: entries, pairs})
  }

  const fixture = {
    source: SOURCE,
    seed: SAMPLE_SEED,
    fields: {
      trips: "[trip id, service date ms]",
      paths: "by trip index: points as an encoded polyline, stops as [meters along the points, arrival s, departure s]",
      reports: "[reported at ms after baseMs, lon, lat, trip index, ms from the report to the first fetch that held it]",
      pairs: "[index of the report the newest fetch before the later report held, index of the later report, the source's position lon, lat in that fetch, the index of the trip that fetch names]"
    },
    baseMs,
    trips,
    paths,
    vehicles
  }
  const text = JSON.stringify(fixture)
  writeFileSync(options.get("out"), gzipSync(text, {level: GZIP_LEVEL}))
  console.log(`vehicles ${vehicles.length}, pairs ${pairCount}, paths ${Object.keys(paths).length}`)
}

function firstOf([first]) {
  return first
}

main()
