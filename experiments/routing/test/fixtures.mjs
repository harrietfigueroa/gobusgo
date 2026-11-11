// Checks the application's engine against the hand-written journeys of the
// fixture file: each case's timetable is written as snapshot files and
// loaded into the engine, and every query's frontier, read back as readable
// legs, must equal the expected one. A query that arrives by a time is also
// checked against the forward scan: leaving at its latest departure arrives
// by the time, and leaving a second later does not. Run it with
// `node test/fixtures.mjs` from the experiment directory; it exits non-zero
// on the first mismatch.

import {readFileSync} from "node:fs"
import {deepStrictEqual} from "node:assert/strict"
import {LegKind, OriginKind} from "../../../assets/js/routing_engine.js"
import {loadEngine} from "../../../assets/js/routing_journeys.js"
import {clock, seconds, snapshotOf} from "../../../test/scripts/routing_timetable.js"

const TRANSFER_S_MIN = 120
const root = new URL("../", import.meta.url)
const fixturesText = readFileSync(new URL("fixtures/journeys.json", root), "utf-8")
const fixtures = JSON.parse(fixturesText)

function readableLeg({leg, snapshot}) {
  if (leg.kind === LegKind.walk) {
    return "walk " + snapshot.stopIds[leg.fromStop] + " " + snapshot.stopIds[leg.toStop] + " " + leg.durationS
  }

  const board = snapshot.connections[leg.boardConnection]
  const alight = snapshot.connections[leg.alightConnection]
  const parts = [
    "ride",
    snapshot.tripIds[board.trip],
    snapshot.stopIds[board.departureStop],
    clock(board.departureS),
    snapshot.stopIds[alight.arrivalStop],
    clock(alight.arrivalS),
  ]
  return parts.join(" ")
}

// A frontier as the readable legs the fixtures are written in.
function readable({frontier, snapshot}) {
  const result = []

  for (const journey of frontier) {
    const legs = []

    for (const leg of journey.legs) {
      legs.push(readableLeg({leg, snapshot}))
    }

    result.push({arrive: clock(journey.arrivalS), changes: journey.changes, legs})
  }

  return result
}

// A frontier arriving by a time, each journey with when it leaves.
function readableArrivingBy({frontier, snapshot}) {
  const leaving = readable({frontier, snapshot})
  const result = []

  for (const [index, journey] of leaving.entries()) {
    result.push({depart: clock(frontier[index].departureS), ...journey})
  }

  return result
}

function earliestArrivalS(frontier) {
  let earliestS = Number.POSITIVE_INFINITY

  for (const journey of frontier) {
    earliestS = Math.min(earliestS, journey.arrivalS)
  }

  return earliestS
}

// The forward scan agrees with the latest departure: from it a journey
// arrives by the time, and from a second later none does.
function checkAgainstForward({engine, routed, frontier, label}) {
  const latestS = frontier[frontier.length - 1].departureS
  const atLatest = engine.route({origin: routed.origin, target: routed.target, departureS: latestS})
  const afterLatest = engine.route({origin: routed.origin, target: routed.target, departureS: latestS + 1})
  deepStrictEqual(earliestArrivalS(atLatest) <= routed.arrivalS, true, label + ", forward from the latest departure")
  deepStrictEqual(earliestArrivalS(afterLatest) > routed.arrivalS, true, label + ", forward from a second later")
}

function checkLeaving({engine, snapshot, query, label}) {
  const routed = {
    origin: {kind: OriginKind.stop, stop: snapshot.stopIndex.get(query.from)},
    target: snapshot.stopIndex.get(query.to),
    departureS: seconds(query.depart),
  }

  const frontier = engine.route(routed)
  deepStrictEqual(readable({frontier, snapshot}), query.expected, label)
}

function checkArrivingBy({engine, snapshot, query, label}) {
  const routed = {
    origin: {kind: OriginKind.stop, stop: snapshot.stopIndex.get(query.from)},
    target: snapshot.stopIndex.get(query.to),
    arrivalS: seconds(query.arriveBy),
  }

  const frontier = engine.routeArrivingBy(routed)
  deepStrictEqual(readableArrivingBy({frontier, snapshot}), query.expected, label)

  if (frontier.length > 0) {
    checkAgainstForward({engine, routed, frontier, label})
  }
}

let checked = 0

for (const fixture of fixtures.cases) {
  const snapshot = snapshotOf(fixture)
  const engine = loadEngine({files: snapshot.files, minimumTransferS: TRANSFER_S_MIN})

  for (const query of fixture.queries) {
    const label = fixture.name + ", " + query.from + " to " + query.to

    if (query.arriveBy === undefined) {
      checkLeaving({engine, snapshot, query, label: label + " leaving at " + query.depart})
    } else {
      checkArrivingBy({engine, snapshot, query, label: label + " arriving by " + query.arriveBy})
    }

    checked += 1
  }
}

console.log("routing fixtures: " + checked + " frontiers match")
