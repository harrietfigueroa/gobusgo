// What the map's camera moves and the page's motion preference say, read once
// for the two follows, the location button's and a bus's.

const REDUCED_MOTION_QUERY = "(prefers-reduced-motion: reduce)"

/** Whether the browser asks for reduced motion. */
export function isReducedMotion() {
  return window.matchMedia(REDUCED_MOTION_QUERY).matches
}

// MapLibre fires a resize's camera events with the ResizeObserver's entries
// as their event data, which leaves the first entry at the key 0.
/** Whether the camera event `event` is the map's resize and not a move of the camera. */
export function isResizeMove(event) {
  const hasResizeObserver = typeof ResizeObserverEntry === "function"
  const isResize = hasResizeObserver && event[0] instanceof ResizeObserverEntry
  return isResize
}
