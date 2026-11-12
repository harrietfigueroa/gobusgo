// The rules of the vehicle page's cold start with no network. Everything
// here is pure: the host's phase, the address's query, what the browser
// stored, and the saved snapshots are given as values, so each decision is
// a function of them alone.
//
// A copy of the page opened offline mounts its hooks from an offline host
// until LiveView's first join, which hands them over to LiveView. The host
// mounts them with the filter of the address where it holds one LiveView
// would accept, and otherwise the stored filter, read as the server reads
// a filter: the agency and route fields, each value text of at most
// FILTER_VALUE_BYTES_MAX bytes, at most FILTER_VALUE_COUNT_MAX values a
// field, and an empty value dropped.

import {assertCondition, unreachable} from "./core/assert.js"
import {TableKind} from "./core/offline_answers.js"
import {FilterKind} from "./stored_settings.js"

/** The most values a field of a filter holds, `Gobusgo.Filter`'s bound. */
export const FILTER_VALUE_COUNT_MAX = 50

/** The most bytes a value of a filter holds, `Gobusgo.Filter`'s bound. */
export const FILTER_VALUE_BYTES_MAX = 128

/** The host's phases: waiting for the page to be offline, reading the overrides, mounted, and handed off to LiveView. */
export const BootPhase = Object.freeze({waiting: "waiting", preparing: "preparing", mounted: "mounted", handedOff: "handedOff"})

/** What reaches the host: the page offline before a join, the overrides read, and the start of LiveView's first patch. */
export const BootEventKind = Object.freeze({offline: "offline", prepared: "prepared", joinPatch: "joinPatch"})

/** A read of a filter: one LiveView would accept, none, or one it would refuse. */
export const ReadFilterKind = Object.freeze({found: "found", none: "none", refused: "refused"})

/** The routes a filter keeps: every route, or the list. */
export const KeptRoutesKind = Object.freeze({every: "every", routes: "routes"})

/** The summary line of a filter: as the copy renders it, or the names to write. */
export const SummaryKind = Object.freeze({rendered: "rendered", named: "named"})

const AGENCY_FIELD = "agency"
const ROUTE_FIELD = "route"
const FILTER_FIELDS = Object.freeze([AGENCY_FIELD, ROUTE_FIELD])
const VALUE_SEPARATOR = ","
// LiveView alone mounts the hook whose `mounted` reports a join.
const LIVE_ONLY_HOOK_NAMES = Object.freeze(["ConnectionState"])

const NO_FILTER = Object.freeze({kind: ReadFilterKind.none})
const REFUSED_FILTER = Object.freeze({kind: ReadFilterKind.refused})
const EVERY_ROUTE = Object.freeze({kind: KeptRoutesKind.every})
const RENDERED = Object.freeze({kind: SummaryKind.rendered})

const encoder = new TextEncoder()

/** The host's phase after `event` reaches it in `phase`. */
export function nextBootPhase({phase, event}) {
  switch (event) {
    case BootEventKind.offline:
      if (phase === BootPhase.waiting) {
        return BootPhase.preparing
      }

      return phase
    case BootEventKind.prepared:
      assertCondition(phase !== BootPhase.waiting, "the overrides are read once the host prepares")

      if (phase === BootPhase.preparing) {
        return BootPhase.mounted
      }

      return phase
    case BootEventKind.joinPatch:
      return BootPhase.handedOff
    default:
      return unreachable(event, "boot event")
  }
}

/** Whether the offline host mounts the hook named `hookName`. */
export function isHostMounted(hookName) {
  assertCondition(typeof hookName === "string", `a hook's name is a text: ${hookName}`)
  return !LIVE_ONLY_HOOK_NAMES.includes(hookName)
}

function isAcceptedValue(value) {
  if (typeof value !== "string") {
    return false
  }

  return encoder.encode(value).length <= FILTER_VALUE_BYTES_MAX
}

// The values of a field LiveView would accept, sorted and once each with
// the empty ones dropped, or refused.
function fieldValuesOf(values) {
  const isList = Array.isArray(values)

  if (!isList) {
    return REFUSED_FILTER
  }

  if (values.length > FILTER_VALUE_COUNT_MAX) {
    return REFUSED_FILTER
  }

  const kept = new Set()

  for (const value of values) {
    if (!isAcceptedValue(value)) {
      return REFUSED_FILTER
    }

    if (value !== "") {
      kept.add(value)
    }
  }

  const sorted = Array.from(kept).sort()
  return {kind: ReadFilterKind.found, values: sorted}
}

// The filter of `raw`, a field's name to its values, as LiveView reads it.
function normalizedOf(raw) {
  const filter = {}

  for (const [field, values] of Object.entries(raw)) {
    if (!FILTER_FIELDS.includes(field)) {
      return REFUSED_FILTER
    }

    const read = fieldValuesOf(values)

    if (read.kind === ReadFilterKind.refused) {
      return read
    }

    if (read.values.length > 0) {
      filter[field] = read.values
    }
  }

  if (Object.keys(filter).length === 0) {
    return NO_FILTER
  }

  return {kind: ReadFilterKind.found, filter}
}

/** The filter the address's query `search` holds, its fields' values separated by commas. */
export function addressFilterOf(search) {
  assertCondition(typeof search === "string", `a query is a text: ${search}`)
  const params = new URLSearchParams(search)
  const raw = {}

  for (const field of FILTER_FIELDS) {
    const all = params.getAll(field)

    if (all.length > 0) {
      const last = all[all.length - 1]
      raw[field] = last.split(VALUE_SEPARATOR)
    }
  }

  return normalizedOf(raw)
}

/** The filter of `stored`, the browser's read of its stored vehicle filter, which can hold anything. */
export function storedFilterOf(stored) {
  if (stored.kind === FilterKind.none) {
    return NO_FILTER
  }

  const {filter} = stored
  const isObject = typeof filter === "object" && filter !== null
  const isMap = isObject && !Array.isArray(filter)

  if (!isMap) {
    return REFUSED_FILTER
  }

  return normalizedOf(filter)
}

/** The filter the host applies: the address's where it holds one LiveView accepts, else the stored one, else none. */
export function bootFilterOf({address, stored}) {
  if (address.kind === ReadFilterKind.found) {
    return address
  }

  if (stored.kind === ReadFilterKind.found) {
    return stored
  }

  return NO_FILTER
}

// The saved route `routeId` of the first names file of `snapshots` that
// holds it, or missing.
function savedRoute({snapshots, routeId}) {
  for (const snapshot of snapshots) {
    const hasNames = snapshot.names.kind === TableKind.found
    const isNamed = hasNames && Object.hasOwn(snapshot.names.table.routes, routeId)

    if (isNamed) {
      return {kind: TableKind.found, route: snapshot.names.table.routes[routeId]}
    }
  }

  return {kind: TableKind.missing}
}

function hasNames(snapshots) {
  for (const snapshot of snapshots) {
    if (snapshot.names.kind === TableKind.found) {
      return true
    }
  }

  return false
}

// Every route of the agencies `agencyIds` the saved names files hold, sorted.
function agencyRouteIds({snapshots, agencyIds}) {
  const routeIds = new Set()

  for (const snapshot of snapshots) {
    if (snapshot.names.kind === TableKind.missing) {
      continue
    }

    for (const [routeId, route] of Object.entries(snapshot.names.table.routes)) {
      if (agencyIds.includes(route.agencyId)) {
        routeIds.add(routeId)
      }
    }
  }

  return Array.from(routeIds).sort()
}

// The routes of `routeIds` that `agencyIds` keep: a route whose agency no
// names file holds is kept, since only its agency could refuse it.
function routesOfAgencies({snapshots, routeIds, agencyIds}) {
  const kept = []

  for (const routeId of routeIds) {
    const saved = savedRoute({snapshots, routeId})
    const isUnknown = saved.kind === TableKind.missing
    const isListed = isUnknown || agencyIds.includes(saved.route.agencyId)

    if (isListed) {
      kept.push(routeId)
    }
  }

  return kept
}

/**
 * The routes `filter`, a read from `bootFilterOf`, keeps, by the saved
 * names files of `snapshots`: its routes, of its agencies where it names
 * any; for agencies alone the routes the names files list for them; and
 * every route for no filter, or for agencies with no names file saved.
 */
export function keptRoutesOf({filter, snapshots}) {
  if (filter.kind !== ReadFilterKind.found) {
    return EVERY_ROUTE
  }

  const agencyIds = filter.filter[AGENCY_FIELD]
  const routeIds = filter.filter[ROUTE_FIELD]
  const namesAgencies = agencyIds !== undefined

  if (routeIds !== undefined) {
    if (namesAgencies) {
      return {kind: KeptRoutesKind.routes, routeIds: routesOfAgencies({snapshots, routeIds, agencyIds})}
    }

    return {kind: KeptRoutesKind.routes, routeIds}
  }

  assertCondition(namesAgencies, "a found filter names agencies or routes")

  if (!hasNames(snapshots)) {
    return EVERY_ROUTE
  }

  return {kind: KeptRoutesKind.routes, routeIds: agencyRouteIds({snapshots, agencyIds})}
}

function routeNameOf({snapshots, routeId}) {
  const saved = savedRoute({snapshots, routeId})

  if (saved.kind === TableKind.missing) {
    return routeId
  }

  const {shortName, longName} = saved.route

  if (typeof shortName === "string") {
    return shortName
  }

  if (typeof longName === "string") {
    return longName
  }

  return routeId
}

function agencyNameOf({snapshots, agencyId}) {
  for (const snapshot of snapshots) {
    const isFound = snapshot.names.kind === TableKind.found
    const isNamed = isFound && Object.hasOwn(snapshot.names.table.agencyNames, agencyId)

    if (isNamed) {
      return snapshot.names.table.agencyNames[agencyId]
    }
  }

  return agencyId
}

/**
 * The summary line of `filter`: as the bare copy renders it for no filter,
 * which shows every vehicle, and otherwise each agency and route by its
 * saved name, or by its identifier where no names file holds it.
 */
export function summaryOf({filter, snapshots}) {
  if (filter.kind !== ReadFilterKind.found) {
    return RENDERED
  }

  const agencyIds = filter.filter[AGENCY_FIELD]
  const routeIds = filter.filter[ROUTE_FIELD]
  const agencyNames = []
  const routeNames = []

  if (agencyIds !== undefined) {
    for (const agencyId of agencyIds) {
      agencyNames.push(agencyNameOf({snapshots, agencyId}))
    }
  }

  if (routeIds !== undefined) {
    for (const routeId of routeIds) {
      routeNames.push(routeNameOf({snapshots, routeId}))
    }
  }

  return {kind: SummaryKind.named, agencyNames, routeNames}
}
