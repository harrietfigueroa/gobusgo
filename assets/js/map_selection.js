// What a tap on the vehicle map does to the details view, as a pure
// function of what the tap hit and what the view shows. Nothing here reads
// the map or the document.

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
