// How far the map moves to bring a place out from under the panel sheet, as
// a pure function of the place's point and the part of the view the sheet
// covers.

const HALVING_DIVISOR = 2

// How far the map moves `point`, in pixels of a view of `viewWidth` by
// `viewHeight`, to bring it out from under a sheet that covers `insets`:
// along each axis on which it lies within `marginPixels` of the sheet, to
// the middle of the part the sheet leaves, and not at all along the other,
// so a point with room for its callout stays where it is.
export function revealOffset({point, viewWidth, viewHeight, insets, marginPixels}) {
  const isCoveredBottom = point.y > viewHeight - insets.bottom - marginPixels
  const isCoveredLeft = point.x < insets.left + marginPixels
  let x = 0
  let y = 0

  if (isCoveredLeft) {
    const middleX = insets.left + (viewWidth - insets.left) / HALVING_DIVISOR
    x = Math.round(point.x - middleX)
  }

  if (isCoveredBottom) {
    const middleY = (viewHeight - insets.bottom) / HALVING_DIVISOR
    y = Math.round(point.y - middleY)
  }

  return {x, y}
}

// The offset in pixels, from the middle of the view, of the middle of the
// part of the view a sheet that covers `insets` leaves: the point the
// reveal moves a covered place to, as MapLibre's camera `offset` takes it.
export function freeMiddleOffset(insets) {
  // Subtracting from 0 keeps a sheet of no height at an offset of 0 rather
  // than -0, which the map reads the same and a strict comparison does not.
  return [insets.left / HALVING_DIVISOR, (0 - insets.bottom) / HALVING_DIVISOR]
}
