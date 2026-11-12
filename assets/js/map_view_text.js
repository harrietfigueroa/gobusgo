// What the vehicle map tells a screen reader about its view: the part of
// the map beside the panel sheet, the stop nearest its middle, the sentence
// of what is in view, and when that sentence is announced. Everything here
// is pure and reads no map, clock, or document, so each decision is checked
// against values written out by hand.

import {assertCondition, unreachable} from "./core/assert.js"

// The shortest time between two announcements, so a rider who pans in
// steps hears the view of a step at most this often.
export const ANNOUNCEMENT_GAP_MS = 4_000

const HALVING_DIVISOR = 2

export const PlaceKind = Object.freeze({found: "found", missing: "missing"})

export const MoveEventKind = Object.freeze({started: "started", ended: "ended", rested: "rested"})

export const AnnouncerEffectKind = Object.freeze({none: "none", announce: "announce", wait: "wait"})

/**
 * The announcer before any move: no move under way, none waiting to be
 * announced, and nothing announced yet.
 */
export const initialAnnouncer = Object.freeze({
  moving: false,
  pending: false,
  lastText: "",
  lastAtMs: Number.NEGATIVE_INFINITY
})

/**
 * The part of a map `width` by `height` pixels that the panel sheet leaves
 * in sight, given the `insets` it covers on the left and at the bottom, as
 * the box of its top left and bottom right corners and its middle.
 */
export function viewBox({width, height, insets: {left, bottom}}) {
  assertCondition(left >= 0, `left must not be negative, got: ${left}`)
  assertCondition(bottom >= 0, `bottom must not be negative, got: ${bottom}`)
  assertCondition(left < width, `left must be under the width ${width}, got: ${left}`)
  assertCondition(bottom < height, `bottom must be under the height ${height}, got: ${bottom}`)

  const right = width
  const lower = height - bottom

  return {
    box: [[left, 0], [right, lower]],
    center: {x: (left + right) / HALVING_DIVISOR, y: lower / HALVING_DIVISOR}
  }
}

/**
 * The name of the place of `places`, each a name at a point on the screen,
 * nearest `center`, the first of those as near, or missing for no place.
 */
export function nearestPlace({places, center}) {
  let nearestName = ""
  let nearestDistanceSquared = Number.POSITIVE_INFINITY

  for (const {name, x, y} of places) {
    assertCondition(name !== "", "a place must have a name")
    const offsetX = x - center.x
    const offsetY = y - center.y
    const distanceSquared = offsetX * offsetX + offsetY * offsetY

    if (distanceSquared < nearestDistanceSquared) {
      nearestName = name
      nearestDistanceSquared = distanceSquared
    }
  }

  if (nearestName === "") {
    return {kind: PlaceKind.missing}
  }

  return {kind: PlaceKind.found, name: nearestName}
}

function countText({count, singular, plural}) {
  assertCondition(Number.isSafeInteger(count), `a count must be an integer, got: ${count}`)
  assertCondition(count >= 0, `a count must not be negative, got: ${count}`)

  if (count === 0) {
    return `no ${plural}`
  }

  if (count === 1) {
    return `1 ${singular}`
  }

  return `${count} ${plural}`
}

/**
 * The sentence of what is in view: the counts of vehicles and of stops, and
 * the stop nearest the middle where `nearest` found one. A zoom at which
 * the map draws no stops (`stopsDrawn` false) says to zoom in for them.
 */
export function viewSentence({vehicleCount, stopCount, stopsDrawn, nearest}) {
  const vehicles = countText({count: vehicleCount, singular: "vehicle", plural: "vehicles"})

  if (!stopsDrawn) {
    assertCondition(stopCount === 0, `a zoom that draws no stops counts none, got: ${stopCount}`)
    return `In view: ${vehicles}. Zoom in to show the stops.`
  }

  const stops = countText({count: stopCount, singular: "stop", plural: "stops"})

  switch (nearest.kind) {
    case PlaceKind.found:
      return `In view: ${vehicles} and ${stops}, centered near ${nearest.name}.`
    case PlaceKind.missing:
      return `In view: ${vehicles} and ${stops}.`
    default:
      return unreachable(nearest.kind, "an unknown place kind")
  }
}

function restedStep({state, nowMs, text}) {
  const isWaiting = state.pending && !state.moving

  if (!isWaiting) {
    return {state, effect: {kind: AnnouncerEffectKind.none}}
  }

  if (text === state.lastText) {
    return {state: {...state, pending: false}, effect: {kind: AnnouncerEffectKind.none}}
  }

  const elapsedMs = nowMs - state.lastAtMs

  if (elapsedMs < ANNOUNCEMENT_GAP_MS) {
    return {state, effect: {kind: AnnouncerEffectKind.wait, ms: ANNOUNCEMENT_GAP_MS - elapsedMs}}
  }

  return {
    state: {...state, pending: false, lastText: text, lastAtMs: nowMs},
    effect: {kind: AnnouncerEffectKind.announce, text}
  }
}

/**
 * The announcer's next state, and what to do, after `event`: a camera move
 * started, a move ended (`announced` for a move the rider made or a fit),
 * or the map rested at `nowMs` showing what `text` says. A rest announces
 * after an announced move alone, never during a move, never the text
 * announced last, and at most once in `ANNOUNCEMENT_GAP_MS`; a rest inside
 * the gap says how long to wait before the next rest is read.
 */
export function announcerStep({state, event}) {
  switch (event.kind) {
    case MoveEventKind.started:
      return {state: {...state, moving: true}, effect: {kind: AnnouncerEffectKind.none}}
    case MoveEventKind.ended:
      return {
        state: {...state, moving: false, pending: state.pending || event.announced},
        effect: {kind: AnnouncerEffectKind.none}
      }
    case MoveEventKind.rested:
      return restedStep({state, nowMs: event.nowMs, text: event.text})
    default:
      return unreachable(event.kind, "an unknown move event kind")
  }
}
