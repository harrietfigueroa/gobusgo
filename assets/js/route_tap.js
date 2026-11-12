// What a tap on the vehicle map does to the list of the routes under it, as
// a pure function of the device and of what lies under the tap. Nothing
// here reads the map or the document.

export const DeviceKind = Object.freeze({hover: "hover", touch: "touch"})
export const TapAction = Object.freeze({close: "close", none: "none", open: "open"})

/** `touch` for a device whose primary pointer cannot hover, `hover` for any other. */
export function deviceKind({isHoverNone}) {
  if (isHoverNone) {
    return DeviceKind.touch
  } else {
    return DeviceKind.hover
  }
}

/**
 * What a tap does to the list: on a touch device, lines under a tap that
 * hits no item open it, and any other tap closes a list that is shown, a tap
 * on an item included, which is the item's own listener's to answer. A
 * device that hovers leaves the list to hover.
 */
export function tapAction({kind, isItemHit, hasLines, isShown}) {
  if (kind === DeviceKind.hover) {
    return TapAction.none
  }

  const isLineTap = hasLines && !isItemHit

  if (isLineTap) {
    return TapAction.open
  } else if (isShown) {
    return TapAction.close
  } else {
    return TapAction.none
  }
}
