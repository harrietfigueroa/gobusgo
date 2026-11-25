// What a tap on the vehicle map does to the details view, as pure functions
// of what the tap hit and what the view shows. Nothing here reads the map or
// the document.

import {assertCondition} from "#core/assert.js"

export const TapOutcome = Object.freeze({deselect: "deselect", none: "none"})

/**
 * What a tap does to the details view: a tap that hits no item while the
 * view shows one deselects it, and a tap on an item is the item's own
 * listener's to answer.
 */
export function tapOutcome({isItemHit, isShowing}) {
  const isEmptyTapOnShown = isShowing && !isItemHit

  if (isEmptyTapOnShown) {
    return TapOutcome.deselect
  }

  return TapOutcome.none
}

/** What the stop signs near a tap open: nothing, one stop, or a list of them. */
export const StopTapKind = Object.freeze({none: "none", one: "one", list: "list"})

/** The fewest stops a list of the stops under a tap holds; one stop opens alone. */
export const LIST_COUNT_MIN = 2

// The square of the distance from `point` to the nearest point of the
// square sign of `halfSize` around `center`, 0 inside it.
function signDistanceSquared({point, center, halfSize}) {
  const outsideX = Math.max(Math.abs(point.x - center.x) - halfSize, 0)
  const outsideY = Math.max(Math.abs(point.y - center.y) - halfSize, 0)
  return outsideX * outsideX + outsideY * outsideY
}

function byNearness(left, right) {
  if (left.distanceSquared !== right.distanceSquared) {
    return left.distanceSquared - right.distanceSquared
  }

  if (left.isUnderTap !== right.isUnderTap) {
    return Number(right.isUnderTap) - Number(left.isUnderTap)
  }

  return left.id.localeCompare(right.id, "en", {sensitivity: "variant", numeric: false})
}

/**
 * What a tap at `point` opens among `candidates`, the stop signs drawn near
 * it, each `{id, item, center, halfSize, isUnderTap}` with its box on the
 * screen and whether the map draws it under `point`. A tap where the map
 * draws no sign opens nothing, so the lines under it stay reachable. A tap
 * on a drawn sign reaches every sign drawn under it and every sign within
 * `radiusPixels` of it, measured to each sign's box, counted once per `id`,
 * since a stop near a tile's edge comes back from each tile: one opens its
 * `item`, and two or more open a list of their `items`, nearest first, a
 * sign drawn under the tap at the tap and before another as near, then by
 * `id`, at most `countMax`, with `count`, every stop reached.
 */
export function stopTapOutcome({candidates, point, radiusPixels, countMax}) {
  assertCondition(radiusPixels >= 0, `a tap's radius is not negative, got: ${radiusPixels}`)
  assertCondition(countMax >= LIST_COUNT_MIN, `a list holds at least ${LIST_COUNT_MIN} stops, got: ${countMax}`)
  const radiusSquared = radiusPixels * radiusPixels
  const nearestById = new Map()
  let isAnyUnderTap = false

  for (const candidate of candidates) {
    let distanceSquared = signDistanceSquared({point, center: candidate.center, halfSize: candidate.halfSize})

    if (candidate.isUnderTap) {
      distanceSquared = 0
      isAnyUnderTap = true
    }

    if (distanceSquared > radiusSquared) {
      continue
    }

    const held = nearestById.get(candidate.id)
    const near = {id: candidate.id, item: candidate.item, distanceSquared, isUnderTap: candidate.isUnderTap}
    const isFirstOrNearer = held === undefined || distanceSquared < held.distanceSquared

    if (isFirstOrNearer) {
      nearestById.set(candidate.id, near)
    }
  }

  // `Array.from` copies the map's values, which `sort` reorders in place.
  const nearest = Array.from(nearestById.values()).sort(byNearness)

  if (!isAnyUnderTap) {
    return {kind: StopTapKind.none}
  }

  if (nearest.length === 1) {
    return {kind: StopTapKind.one, item: nearest[0].item}
  }

  const items = []

  for (const near of nearest.slice(0, countMax)) {
    items.push(near.item)
  }

  return {kind: StopTapKind.list, items, count: nearest.length}
}
