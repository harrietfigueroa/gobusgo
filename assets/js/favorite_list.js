// The rules of the Favorites tab's list, as pure functions of values: where
// a dragged entry drops, which move buttons an entry offers, the text that
// announces a move, and the camera move that centers the map on a chosen
// favorite. Nothing here reads the document or the map.

import {freeMiddleOffset} from "./reveal_offset.js"

/** How long the move to a chosen favorite eases, where the browser does not ask for reduced motion. */
export const FAVORITE_EASE_MS = 500

/** The zoom the move to a chosen favorite reaches at least, at which a street's stops stand apart with room for their route chips. */
export const FAVORITE_ZOOM_MIN = 16

/**
 * The index a dragged entry drops at, with the pointer at `pointerY`: the
 * count of the other entries, whose vertical middles are `middles`, that
 * the pointer has passed.
 */
export function dropIndex({pointerY, middles}) {
  let index = 0

  for (const middle of middles) {
    if (pointerY > middle) {
      index += 1
    }
  }

  return index
}

/** Which move buttons the entry at `index` of `count` disables: up for the first, down for the last. */
export function moveButtonsOf({index, count}) {
  const lastIndex = count - 1
  return {isUpDisabled: index === 0, isDownDisabled: index === lastIndex}
}

/** The announcement of an entry moved to `index` of `count`. */
export function moveText({index, count}) {
  const position = index + 1
  return `Moved to ${position} of ${count}`
}

/**
 * The camera of the move to a favorite's stop at `lngLat`, from a map at
 * `zoom`: centered in the part of the map a sheet that covers `insets`
 * leaves, at `zoomMin` or closer, and a jump where the browser asks for
 * reduced motion. North stays up: the camera names no bearing.
 */
export function favoriteCamera({lngLat, zoom, zoomMin, insets, reducedMotion}) {
  let duration = FAVORITE_EASE_MS

  if (reducedMotion) {
    duration = 0
  }

  return {
    center: lngLat,
    zoom: Math.max(zoom, zoomMin),
    offset: freeMiddleOffset(insets),
    duration
  }
}
