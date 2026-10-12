// The rule that keeps open popups apart. Everything here is pure: it reads
// screen positions and sizes as values and no map and no document, so the
// rule runs wherever JavaScript does.

// The sides of its point a popup stands on, in the order they are tried.
export const sides = ["above", "below", "left", "right"]

// The box of a popup of `size`, the size of its content, that stands on
// `side` of `point` with a tip of `tipLength` between the two.
export function popupBox({point, size, side, tipLength}) {
  const {width, height} = size

  switch (side) {
    case "above":
      return box({left: point.x - width / 2, top: point.y - tipLength - height, width, height: height + tipLength})
    case "below":
      return box({left: point.x - width / 2, top: point.y, width, height: height + tipLength})
    case "left":
      return box({left: point.x - tipLength - width, top: point.y - height / 2, width: width + tipLength, height})
    case "right":
      return box({left: point.x, top: point.y - height / 2, width: width + tipLength, height})
    default:
      throw new Error(`unknown popup side: ${side}`)
  }
}

function box({left, top, width, height}) {
  return {left, top, right: left + width, bottom: top + height}
}

function grown(rectangle, pixels) {
  return {
    left: rectangle.left - pixels,
    top: rectangle.top - pixels,
    right: rectangle.right + pixels,
    bottom: rectangle.bottom + pixels
  }
}

function crosses(first, second) {
  const crossesAcross = first.left < second.right && second.left < first.right
  const crossesDown = first.top < second.bottom && second.top < first.bottom
  return crossesAcross && crossesDown
}

function within(rectangle, view) {
  const withinAcross = rectangle.left >= 0 && rectangle.right <= view.width
  const withinDown = rectangle.top >= 0 && rectangle.bottom <= view.height
  return withinAcross && withinDown
}

// The area of the part of a rectangle that lies inside the view.
function areaWithin(rectangle, view) {
  const width = Math.min(rectangle.right, view.width) - Math.max(rectangle.left, 0)
  const height = Math.min(rectangle.bottom, view.height) - Math.max(rectangle.top, 0)
  return Math.max(width, 0) * Math.max(height, 0)
}

function distanceSquared(point, other) {
  return (point.x - other.x) ** 2 + (point.y - other.y) ** 2
}

// How far each side reaches along a direction.
const reachBySide = {
  above: ({y}) => -y,
  below: ({y}) => y,
  left: ({x}) => -x,
  right: ({x}) => x
}

// A popup's sides in the order they are tried: the side that faces away
// from the middle of the other popups' points first, so the popups of
// points that stand close together open away from each other. A popup with
// no other is tried above its point first.
function sidesAwayFrom({point, others}) {
  if (others.length === 0) {
    return sides
  }

  const middle = {
    x: others.reduce((sum, other) => sum + other.x, 0) / others.length,
    y: others.reduce((sum, other) => sum + other.y, 0) / others.length
  }
  const direction = {x: point.x - middle.x, y: point.y - middle.y}

  // The sort is stable, so sides that reach equally far keep their order.
  return [...sides].sort((first, second) => reachBySide[second](direction) - reachBySide[first](direction))
}

// The side of `sidesTried` a popup takes among those whose box crosses
// none of `taken`: the first whose box lies inside the view, or else the
// one whose box has the most of its area inside it, the earlier of two
// with as much. Null for a popup every side of which crosses a taken box.
function freeSide({popup, sidesTried, taken, view, tipLength, gapPixels}) {
  let partial = null

  for (const side of sidesTried) {
    const candidate = popupBox({point: popup.point, size: popup.size, side, tipLength})
    const kept = grown(candidate, gapPixels)

    if (taken.some((other) => crosses(kept, other))) {
      continue
    }

    if (within(candidate, view)) {
      return {side, box: candidate}
    }

    const area = areaWithin(candidate, view)

    if (partial === null || area > partial.area) {
      partial = {side, box: candidate, area}
    }
  }

  return partial
}

// The side each popup of `popups` stands on, by the popup's `id`, so that
// no two of their boxes cross and none crosses a box of `obstacles`, with
// `gapPixels` between any two. A popup has the `point` of the view it
// points at and the `size` of its content. The popup nearest the middle of
// `view` gets its side first, then the others by distance from the middle.
// A popup with no free side is left out.
export function placePopups({popups, obstacles, view, tipLength, gapPixels}) {
  const middle = {x: view.width / 2, y: view.height / 2}
  const ordered = [...popups].sort(
    (first, second) => distanceSquared(first.point, middle) - distanceSquared(second.point, middle)
  )
  const taken = [...obstacles]
  const sidesById = new Map()

  for (const popup of ordered) {
    const others = popups.filter((other) => other !== popup).map((other) => other.point)
    const sidesTried = sidesAwayFrom({point: popup.point, others})
    const free = freeSide({popup, sidesTried, taken, view, tipLength, gapPixels})

    if (free !== null) {
      sidesById.set(popup.id, free.side)
      taken.push(free.box)
    }
  }

  return sidesById
}
