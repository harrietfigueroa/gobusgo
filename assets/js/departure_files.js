// Reads the scheduled departures at a stop from the routing manifest and the
// files it names, for the arrivals board: the service date a time falls in,
// that date's stops, trips, and names files, and the connection chunks that
// hold a departure at or after the time, one at a time until the list is
// full. Every file goes through a function the caller hands in, which
// receives a path the manifest names and nothing else.
//
// The date a time falls in holds the trips of the date and the previous
// date's trips running past its start, so the departures past midnight are
// in it. The next date is read only where the first has no departure at the
// stop from the time, since the list is the next scheduled departures and a
// date that has some leaves nothing to read ahead for.

import {assertCondition} from "./assert.js"
import {TableKind} from "./offline_answers.js"
import {FailureReason, JourneysKind, decodedOrFailed, fetchChecked} from "./routing_journeys.js"
import {DecodeKind, decodeConnections, decodeStops, decodeTrips} from "./routing_snapshot.js"
import {decodeNames, expandNames} from "./routing_names.js"
import {DeparturesKind, chunksFrom, scheduledDepartures} from "./scheduled_service.js"

/** The longest a service day lasts: a day of 24 hours and the hour a change of daylight saving time adds. */
export const SERVICE_DAY_MS_MAX = 25 * 60 * 60 * 1000

/** The most connection chunks of one date a read fetches; a manifest entry with more is refused. */
export const DEPARTURE_CHUNK_COUNT_MAX = 48

/** The kinds of what a read of the departures ends in. */
export const DepartureLoadKind = Object.freeze({listed: "listed", noSchedule: "noSchedule", unknownStop: "unknownStop", failed: "failed"})

const EntriesKind = Object.freeze({found: "found", none: "none"})
const NO_POSITIONS = Object.freeze({kind: TableKind.missing})
const NAMES_MISSING = Object.freeze({kind: TableKind.missing})

function failedOf({reason, path}) {
  return {kind: DepartureLoadKind.failed, reason, path}
}

/**
 * The manifest entries a list of departures from `fromMs`, milliseconds since
 * the Unix epoch, reads: an EntriesKind member, found with `entries`, the
 * date the time falls in, the latest that started by it, and the next date
 * where it starts within a service day of the first; or none where no date
 * has started by the time or the time is past the date's longest day.
 */
export function entriesFor({manifest, fromMs}) {
  let covering = null

  for (const entry of manifest.snapshots) {
    const isStarted = entry.serviceDayStartMs <= fromMs
    const isLaterStart = covering === null || entry.serviceDayStartMs > covering.serviceDayStartMs

    const isCovering = isStarted && isLaterStart

    if (isCovering) {
      covering = entry
    }
  }

  if (covering === null) {
    return {kind: EntriesKind.none}
  }

  const dayEndMs = covering.serviceDayStartMs + SERVICE_DAY_MS_MAX

  if (fromMs >= dayEndMs) {
    return {kind: EntriesKind.none}
  }

  let next = null

  for (const entry of manifest.snapshots) {
    const isAfter = entry.serviceDayStartMs > covering.serviceDayStartMs
    const isSoonest = next === null || entry.serviceDayStartMs < next.serviceDayStartMs
    const isNextDay = entry.serviceDayStartMs <= dayEndMs

    const isNextCandidate = isAfter && isSoonest
    const isNext = isNextCandidate && isNextDay

    if (isNext) {
      next = entry
    }
  }

  if (next === null) {
    return {kind: EntriesKind.found, entries: [covering]}
  }

  return {kind: EntriesKind.found, entries: [covering, next]}
}

async function fetchTable({fetchFile, file, decode}) {
  const fetched = await fetchChecked({fetchFile, file})

  if (fetched.kind === JourneysKind.failed) {
    return fetched
  }

  return decodedOrFailed({fetched, decode, path: file.path})
}

// The names of `entry`'s snapshot, or missing where the file is not read: a departure then shows its route's identifier.
async function namesOf({fetchFile, entry, stopCount}) {
  const fetched = await fetchChecked({fetchFile, file: entry.files.names})

  if (fetched.kind === JourneysKind.failed) {
    return NAMES_MISSING
  }

  const expanded = await expandNames(fetched.buffer)

  if (expanded.kind === DecodeKind.refused) {
    return NAMES_MISSING
  }

  const decoded = decodeNames({buffer: expanded.records, stopCount, tripCount: entry.tripCount})

  if (decoded.kind === DecodeKind.refused) {
    return NAMES_MISSING
  }

  return {kind: TableKind.found, table: decoded.records}
}

function stopIndexesOf(stopIds) {
  const indexes = new Map()

  for (const [index, stopId] of stopIds.entries()) {
    indexes.set(stopId, index)
  }

  return indexes
}

// The saved snapshot of `entry`, as `scheduledDepartures` reads one, with no connection yet, or the failure of its stops or trips file.
async function snapshotOf({fetchFile, entry}) {
  const stops = await fetchTable({fetchFile, file: entry.files.stops, decode: decodeStops})

  if (stops.kind === JourneysKind.failed) {
    return stops
  }

  const trips = await fetchTable({fetchFile, file: entry.files.trips, decode: decodeTrips})

  if (trips.kind === JourneysKind.failed) {
    return trips
  }

  const names = await namesOf({fetchFile, entry, stopCount: stops.records.length})

  return {
    kind: DecodeKind.decoded,
    snapshot: {
      serviceDate: entry.serviceDate,
      serviceDayStartMs: entry.serviceDayStartMs,
      connectionChunks: entry.connectionChunks,
      stopIndexes: stopIndexesOf(stops.records),
      trips: {kind: TableKind.found, table: trips.records},
      positions: NO_POSITIONS,
      names,
      connections: []
    }
  }
}

function stopNameOf({names, stop}) {
  if (names.kind === TableKind.missing) {
    return null
  }

  const name = names.table.stopNames[stop]

  if (typeof name === "string") {
    return name
  }

  return null
}

// The departures of one date: its chunks from the time onward, fetched one at a time until the list holds `countMax`.
async function listDate({fetchFile, entry, fromMs, stopId, kept, countMax}) {
  if (entry.connectionChunks.length > DEPARTURE_CHUNK_COUNT_MAX) {
    return failedOf({reason: FailureReason.tooManyChunks, path: ""})
  }

  const read = await snapshotOf({fetchFile, entry})

  if (read.kind === JourneysKind.failed) {
    return failedOf(read)
  }

  const {snapshot} = read
  const stop = snapshot.stopIndexes.get(stopId)

  if (stop === undefined) {
    return {kind: DepartureLoadKind.unknownStop}
  }

  const connections = []
  let departures = []

  for (const chunk of chunksFrom({entry, fromMs})) {
    if (departures.length >= countMax) {
      break
    }

    const fetched = await fetchTable({fetchFile, file: chunk, decode: decodeConnections})

    if (fetched.kind === JourneysKind.failed) {
      return failedOf(fetched)
    }

    connections.push(fetched.records)
    const listed = scheduledDepartures({snapshots: [{...snapshot, connections}], stopId, fromMs, kept, countMax})
    assertCondition(listed.kind === DeparturesKind.found, "departure files: a stop the snapshot holds has a list")
    departures = listed.departures
  }

  return {kind: DepartureLoadKind.listed, stopName: stopNameOf({names: snapshot.names, stop}), departures}
}

function listedOf({first, departures, countMax}) {
  return {kind: DepartureLoadKind.listed, stopName: first.stopName, departures, isBounded: departures.length === countMax}
}

/**
 * The scheduled departures from `stopId` at or after `fromMs`, on the routes
 * `kept` keeps, at most `countMax`, read from the files of `manifest`
 * through `fetchFile`. A DepartureLoadKind member: `listed` with the stop's
 * `stopName`, null where no names file is read, the `departures` of
 * `scheduledDepartures`, and `isBounded` for a list that holds `countMax`;
 * `noSchedule` where no date of the manifest holds the time; `unknownStop`
 * where the date's snapshot holds no such stop; or `failed` naming the
 * `reason` and the file's `path`.
 */
export async function loadDepartures({fetchFile, manifest, fromMs, stopId, kept, countMax}) {
  const found = entriesFor({manifest, fromMs})

  if (found.kind === EntriesKind.none) {
    return {kind: DepartureLoadKind.noSchedule}
  }

  const [covering, next] = found.entries
  const first = await listDate({fetchFile, entry: covering, fromMs, stopId, kept, countMax})

  if (first.kind !== DepartureLoadKind.listed) {
    return first
  }

  const isDone = first.departures.length > 0 || next === undefined

  if (isDone) {
    return listedOf({first, departures: first.departures, countMax})
  }

  const second = await listDate({fetchFile, entry: next, fromMs, stopId, kept, countMax})

  if (second.kind === DepartureLoadKind.failed) {
    return second
  }

  if (second.kind === DepartureLoadKind.unknownStop) {
    return listedOf({first, departures: first.departures, countMax})
  }

  return listedOf({first, departures: second.departures, countMax})
}
