// What the hooks share of the popups a rider opens with a click. Such a
// popup keeps its place, and the popups that open by themselves are placed
// around it.

// The class of a popup a rider opened.
export const RIDER_POPUP_CLASS_NAME = "rider-popup"
// The DOM event the window gets when a rider's popup opens or closes.
export const RIDER_POPUP_CHANGE_EVENT_NAME = "gobusgo:rider-popup-change"

export function announceRiderPopupChange() {
  window.dispatchEvent(new CustomEvent(RIDER_POPUP_CHANGE_EVENT_NAME))
}

// The box of each rider's popup that is open on `map`, in the pixels of the
// map's view.
export function riderPopupBoxes(map) {
  const container = map.getContainer()
  const origin = container.getBoundingClientRect()
  const boxes = []

  for (const element of container.querySelectorAll(`.${RIDER_POPUP_CLASS_NAME}`)) {
    const rectangle = element.getBoundingClientRect()

    boxes.push({
      left: rectangle.left - origin.left,
      top: rectangle.top - origin.top,
      right: rectangle.right - origin.left,
      bottom: rectangle.bottom - origin.top
    })
  }

  return boxes
}
