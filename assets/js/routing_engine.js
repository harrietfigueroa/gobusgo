// The connection scan engine over the routing snapshots. Everything here is
// pure: an engine is built from a snapshot's decoded columns and answers a
// query with its Pareto frontier over arrival time and changes.
//
// The scan runs in rounds. Round k finds, at every stop, the earliest
// arrival and the earliest time a rider can board with at most k rides. It
// boards a trip only where the round before could board in time, so a round
// adds exactly one ride, and a rider stays aboard a trip once boarded. A
// query starts from one origin stop, or from a set of start stops each
// reached by a walk of its own from the rider's position. A rider can board
// on arrival at the origin or a start stop or after a walk, and the
// snapshot's minimum transfer after leaving a vehicle. One walking link may
// leave an origin stop, none leaves a start stop, and one may follow each
// ride. Each label keeps the leg that set it, and a walk keeps the ride it
// follows, so the legs read back are the ones the scan used. A round's
// journey joins the frontier only when it arrives strictly earlier than the
// round before, so no journey kept has another that arrives at least as
// early with at most as many changes.
//
// The scan reads the connections from the first one departing at or after
// the query and stops at the first one departing at or after the best
// arrival, so a set of connections cut off at a later departure gives every
// journey that arrives by that departure exactly as the whole set does.

import {assertCondition, unreachable} from "./assert.js"

export const ROUNDS_MAX = 6
export const LegKind = Object.freeze({ride: "ride", walk: "walk", walkFromPosition: "walkFromPosition"})

/** The kinds of a query's origin: one stop, or start stops with their walking times. */
export const OriginKind = Object.freeze({stop: "stop", starts: "starts"})

const UNREACHED = 0x7fffffff
const PARENT_NONE = 0
const PARENT_RIDE = 1
const PARENT_WALK_AFTER_RIDE = 2
const PARENT_WALK_FROM_ORIGIN = 3
const PARENT_WALK_FROM_POSITION = 4
const NOT_BOARDED = -1
const LEG_COUNT_MAX = ROUNDS_MAX + ROUNDS_MAX + 1

// The walking links of each stop, as offsets into the flat link columns,
// which the snapshot orders by the stop they leave.
function adjacency({stopCount, transfers}) {
  const offsets = new Uint32Array(stopCount + 1)

  for (const fromStop of transfers.fromStop) {
    offsets[fromStop + 1] += 1
  }

  for (let stop = 0; stop < stopCount; stop++) {
    offsets[stop + 1] += offsets[stop]
  }

  return {offsets, toStop: transfers.toStop, durationS: transfers.durationS}
}

function tripCount(trips) {
  let count = 0

  for (const trip of trips) {
    count = Math.max(count, trip + 1)
  }

  return count
}

/** An engine over a snapshot's stop count, connections, walking links, and minimum transfer. */
export function createEngine({stopCount, connections, transfers, minimumTransferS}) {
  return {
    stopCount,
    connections,
    links: adjacency({stopCount, transfers}),
    minimumTransferS,
    tripCount: tripCount(connections.trip),
  }
}

// The index of the first connection departing at or after `departureS`.
function firstConnection({departureS, connections}) {
  let low = 0
  let high = connections.departureS.length

  while (low < high) {
    const middle = (low + high) >>> 1

    if (connections.departureS[middle] < departureS) {
      low = middle + 1
    } else {
      high = middle
    }
  }

  return low
}

// One label of a round: per stop, its time and the leg that set it. A label
// owns its arrays and changes them only through `improve`.
class Label {
  constructor(columns) {
    this.timeS = columns.timeS
    this.kind = columns.kind
    this.a = columns.a
    this.b = columns.b
    this.c = columns.c
    this.round = columns.round
  }

  static unreached(stopCount) {
    return new Label({
      timeS: new Int32Array(stopCount).fill(UNREACHED),
      kind: new Uint8Array(stopCount),
      a: new Int32Array(stopCount),
      b: new Int32Array(stopCount),
      c: new Int32Array(stopCount),
      round: new Uint8Array(stopCount),
    })
  }

  copy() {
    return new Label({
      timeS: this.timeS.slice(),
      kind: this.kind.slice(),
      a: this.a.slice(),
      b: this.b.slice(),
      c: this.c.slice(),
      round: this.round.slice(),
    })
  }

  // Sets the label at `stop` when `timeS` is earlier, with the leg that reached it.
  improve({stop, timeS, kind, a, b, c, round}) {
    if (timeS < this.timeS[stop]) {
      this.timeS[stop] = timeS
      this.kind[stop] = kind
      this.a[stop] = a
      this.b[stop] = b
      this.c[stop] = c
      this.round[stop] = round
    }
  }
}

// Walks every link from `stop`, reached at `arrivalS` by the ride that
// boarded at connection `board` and left at `alight`, or from the origin
// when `board` is NOT_BOARDED. A walk keeps the ride it follows, so reading
// it back never depends on a label a later walk overwrote.
function walkFrom({engine, state, roundIndex, stop, arrivalS, board, alight}) {
  const {offsets, toStop, durationS} = engine.links
  let kind = PARENT_WALK_AFTER_RIDE

  if (board === NOT_BOARDED) {
    kind = PARENT_WALK_FROM_ORIGIN
  }

  for (let link = offsets[stop]; link < offsets[stop + 1]; link++) {
    const step = {stop: toStop[link], timeS: arrivalS + durationS[link], kind, a: board, b: alight, c: durationS[link], round: roundIndex}
    state.arrival.improve(step)
    state.ready.improve(step)
  }
}

function scanRound({engine, previous, state, roundIndex, query}) {
  const {connections, minimumTransferS} = engine
  const boardedAt = new Int32Array(engine.tripCount).fill(NOT_BOARDED)
  const count = connections.departureS.length

  for (let index = firstConnection({departureS: query.departureS, connections}); index < count; index++) {
    const departureS = connections.departureS[index]

    if (departureS >= state.arrival.timeS[query.target]) {
      break
    }

    const trip = connections.trip[index]
    const departureStop = connections.departureStop[index]
    const isBoardingStop = connections.boarding[index] === 1
    const isBoardable = isBoardingStop && previous.ready.timeS[departureStop] <= departureS
    const isFirstBoarding = boardedAt[trip] === NOT_BOARDED && isBoardable

    if (isFirstBoarding) {
      boardedAt[trip] = index
    }

    const isAboard = boardedAt[trip] !== NOT_BOARDED
    const isAlighting = isAboard && connections.alighting[index] === 1
    const arrivalStop = connections.arrivalStop[index]
    const arrivalS = connections.arrivalS[index]
    const isEarlier = isAlighting && arrivalS < state.arrival.timeS[arrivalStop]

    if (isEarlier) {
      const ride = {stop: arrivalStop, kind: PARENT_RIDE, a: boardedAt[trip], b: index, c: 0, round: roundIndex}
      state.arrival.improve({...ride, timeS: arrivalS})
      state.ready.improve({...ride, timeS: arrivalS + minimumTransferS})
      walkFrom({engine, state, roundIndex, stop: arrivalStop, arrivalS, board: boardedAt[trip], alight: index})
    }
  }
}

// The legs of the journey that reaches `query.target` in round `roundIndex`.
// A ride's boarding stop is read back through the ready label of the round
// before, which is what the scan boarded on.
function legs({engine, rounds, roundIndex, query}) {
  const {connections} = engine
  const result = []
  let stop = query.target
  let current = roundIndex
  let labelName = "arrival"

  for (let step = 0; step < LEG_COUNT_MAX; step++) {
    const label = rounds[current][labelName]
    const kind = label.kind[stop]

    if (kind === PARENT_NONE) {
      return result
    }

    if (kind === PARENT_WALK_FROM_ORIGIN) {
      result.unshift({kind: LegKind.walk, fromStop: query.origin.stop, toStop: stop, durationS: label.c[stop]})
      return result
    }

    if (kind === PARENT_WALK_FROM_POSITION) {
      result.unshift({kind: LegKind.walkFromPosition, toStop: stop, durationS: label.c[stop]})
      return result
    }

    const board = label.a[stop]
    const alight = label.b[stop]

    if (kind === PARENT_WALK_AFTER_RIDE) {
      result.unshift({kind: LegKind.walk, fromStop: connections.arrivalStop[alight], toStop: stop, durationS: label.c[stop]})
    }

    result.unshift({kind: LegKind.ride, boardConnection: board, alightConnection: alight})
    current = label.round[stop] - 1
    stop = connections.departureStop[board]
    labelName = "ready"
  }

  assertCondition(false, "routing engine: a journey has more legs than its rounds allow")
  return result
}

function rideCount(journeyLegs) {
  let count = 0

  for (const leg of journeyLegs) {
    if (leg.kind === LegKind.ride) {
      count += 1
    }
  }

  return count
}

function isStop({engine, stop}) {
  const isIndex = Number.isInteger(stop) && stop >= 0
  return isIndex && stop < engine.stopCount
}

function stopOriginState({engine, query}) {
  const {stop} = query.origin
  assertCondition(isStop({engine, stop}), "routing engine: the origin stop " + stop + " is not a stop of the snapshot")
  const state = {arrival: Label.unreached(engine.stopCount), ready: Label.unreached(engine.stopCount)}
  state.arrival.timeS[stop] = query.departureS
  state.ready.timeS[stop] = query.departureS
  walkFrom({engine, state, roundIndex: 0, stop, arrivalS: query.departureS, board: NOT_BOARDED, alight: NOT_BOARDED})
  return state
}

function startsOriginState({engine, query}) {
  const {starts} = query.origin
  assertCondition(starts.length >= 1, "routing engine: a query from start stops names none")
  const state = {arrival: Label.unreached(engine.stopCount), ready: Label.unreached(engine.stopCount)}

  for (const start of starts) {
    assertCondition(isStop({engine, stop: start.stop}), "routing engine: the start stop " + start.stop + " is not a stop of the snapshot")
    assertCondition(Number.isInteger(start.walkS), "routing engine: a start stop's walk is not whole seconds: " + start.walkS)
    assertCondition(start.walkS >= 0, "routing engine: a start stop's walk is negative: " + start.walkS)
    const step = {stop: start.stop, timeS: query.departureS + start.walkS, kind: PARENT_WALK_FROM_POSITION, a: NOT_BOARDED, b: NOT_BOARDED, c: start.walkS, round: 0}
    state.arrival.improve(step)
    state.ready.improve(step)
  }

  return state
}

function originState({engine, query}) {
  switch (query.origin.kind) {
    case OriginKind.stop:
      return stopOriginState({engine, query})
    case OriginKind.starts:
      return startsOriginState({engine, query})
    default:
      return unreachable(query.origin.kind, "routing engine: an origin of unknown kind")
  }
}

/**
 * The Pareto frontier of journeys from `query.origin` to `query.target`
 * leaving at or after `query.departureS`, fewest changes first: each with
 * its arrival, its changes, and its legs. An origin is one stop,
 * `{kind: OriginKind.stop, stop}`, or start stops each with the whole
 * seconds of its walk from the rider's position,
 * `{kind: OriginKind.starts, starts: [{stop, walkS}]}`.
 */
export function route(engine, query) {
  assertCondition(isStop({engine, stop: query.target}), "routing engine: the target " + query.target + " is not a stop of the snapshot")
  assertCondition(Number.isInteger(query.departureS), "routing engine: the departure is not whole seconds: " + query.departureS)
  const rounds = [originState({engine, query})]
  const frontier = []
  let bestS = rounds[0].arrival.timeS[query.target]

  if (bestS < UNREACHED) {
    frontier.push({arrivalS: bestS, changes: 0, legs: legs({engine, rounds, roundIndex: 0, query})})
  }

  for (let roundIndex = 1; roundIndex <= ROUNDS_MAX; roundIndex++) {
    const previous = rounds[roundIndex - 1]
    const state = {arrival: previous.arrival.copy(), ready: previous.ready.copy()}
    scanRound({engine, previous, state, roundIndex, query})
    rounds.push(state)
    const arrivalS = state.arrival.timeS[query.target]

    if (arrivalS < bestS) {
      bestS = arrivalS
      const journeyLegs = legs({engine, rounds, roundIndex, query})
      frontier.push({arrivalS, changes: Math.max(rideCount(journeyLegs) - 1, 0), legs: journeyLegs})
    }
  }

  return frontier
}
