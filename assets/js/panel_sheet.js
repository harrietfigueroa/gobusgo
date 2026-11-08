// The panel sheet of a map page: which tab is open and whether the sheet is
// expanded, held in the browser alone. The server renders the first tab
// open and the sheet collapsed and leaves the attributes that carry the
// state to this hook across patches.

const SHEET_ID = "panel-sheet"
const TAB_SELECTOR = "[role=tab]"
const PANEL_SELECTOR = "[role=tabpanel]"
const INSET_BOTTOM_PROPERTY = "--panel-sheet-inset-bottom"
const EXPAND_LABEL = "Expand the panels"
const COLLAPSE_LABEL = "Collapse the panels"
// A drag of the handle shorter than this is a tap, which the click toggles.
const DRAG_DISTANCE_PIXELS_MIN = 24
// While it is dragged the sheet follows the pointer up to this share of the
// viewport's height.
const DRAG_HEIGHT_FRACTION_MAX = 0.9

// An element inside a panel dispatches this bubbling DOM event to have the
// sheet open that panel's tab and expand.
export const OPEN_EVENT_NAME = "gobusgo:panel-open"

export const DragOutcome = Object.freeze({expand: "expand", collapse: "collapse", none: "none"})

// What a drag of the handle from `startY` to `endY`, in pixels from the top
// of the viewport, does: a drag up expands, a drag down collapses, and a
// shorter one is a tap.
export function dragOutcome({startY, endY}) {
  const distance = startY - endY

  if (distance >= DRAG_DISTANCE_PIXELS_MIN) {
    return DragOutcome.expand
  } else if (distance <= -DRAG_DISTANCE_PIXELS_MIN) {
    return DragOutcome.collapse
  } else {
    return DragOutcome.none
  }
}

// How far a sheet at `sheetRect` covers a viewport of `viewportWidth` by
// `viewportHeight` from its bottom and from its left: a sheet across the
// whole width covers the bottom, and a narrower one covers the left side.
export function coveredInsets({sheetRect, viewportWidth, viewportHeight}) {
  const startsAtLeft = sheetRect.left <= 0
  const spansWidth = startsAtLeft && sheetRect.right >= viewportWidth

  if (spansWidth) {
    return {left: 0, bottom: Math.max(0, viewportHeight - sheetRect.top)}
  } else {
    return {left: Math.max(0, sheetRect.right), bottom: 0}
  }
}

// How far the page's sheet covers the viewport, or nothing on a page that
// has no sheet.
export function sheetInsets() {
  const element = document.getElementById(SHEET_ID)

  if (element === null) {
    return {left: 0, bottom: 0}
  }

  return coveredInsets({
    sheetRect: element.getBoundingClientRect(),
    viewportWidth: window.innerWidth,
    viewportHeight: window.innerHeight
  })
}

// The index of the tab a key moves focus to from `index` among `count`
// tabs, or the index itself for a key that moves nothing.
function movedIndex({key, index, count}) {
  switch (key) {
    case "ArrowLeft":
      return (index - 1 + count) % count
    case "ArrowRight":
      return (index + 1) % count
    case "Home":
      return 0
    case "End":
      return count - 1
    default:
      return index
  }
}

export const PanelSheet = {
  mounted() {
    this.handle = this.el.querySelector("#panel-sheet-handle")
    this.tabs = Array.from(this.el.querySelectorAll(TAB_SELECTOR))
    this.drag = null
    this.dragged = false

    for (const [index, tab] of this.tabs.entries()) {
      tab.addEventListener("click", () => { this.open(index) })
      tab.addEventListener("keydown", (event) => { this.moveFocus({key: event.key, index, event}) })
    }

    this.handle.addEventListener("click", () => { this.toggleCallback() })
    this.handle.addEventListener("pointerdown", (event) => { this.dragStart(event) })
    this.handle.addEventListener("pointermove", (event) => { this.dragMove(event) })
    this.handle.addEventListener("pointerup", (event) => { this.dragEnd(event) })
    this.handle.addEventListener("pointercancel", () => { this.dragCancel() })

    this.el.addEventListener("keydown", (event) => {
      if (event.key === "Escape") {
        this.collapseCallback()
      }
    })

    this.el.addEventListener(OPEN_EVENT_NAME, (event) => { this.openPanelOf(event.target) })

    this.resizeObserver = new ResizeObserver(() => { this.writeInset() })
    this.resizeObserver.observe(this.el)
    this.onResize = () => { this.writeInset() }
    window.addEventListener("resize", this.onResize)
    this.writeInset()
  },

  // Opens the panel of the tab at `openIndex`, closes the others, and
  // expands the sheet. The open tab is the one a keyboard reaches.
  open(openIndex) {
    for (const [index, tab] of this.tabs.entries()) {
      const isOpen = index === openIndex
      tab.setAttribute("aria-selected", String(isOpen))
      document.getElementById(tab.getAttribute("aria-controls")).hidden = isOpen === false

      if (isOpen) {
        tab.tabIndex = 0
      } else {
        tab.tabIndex = -1
      }
    }

    this.setExpanded(true)
  },

  // Opens the tab of the panel that holds `element`.
  openPanelOf(element) {
    const panel = element.closest(PANEL_SELECTOR)

    if (panel === null) {
      return
    }

    const index = this.tabs.findIndex((tab) => tab.getAttribute("aria-controls") === panel.id)

    if (index >= 0) {
      this.open(index)
    }
  },

  // The arrow keys, Home, and End move focus among the tabs from the one at
  // `index`; Enter and Space then open the focused one, as a click does.
  moveFocus({key, index, event}) {
    const target = movedIndex({key, index, count: this.tabs.length})

    if (target !== index) {
      event.preventDefault()
      this.tabs[index].tabIndex = -1
      this.tabs[target].tabIndex = 0
      this.tabs[target].focus()
    }
  },

  // A collapsed sheet hides its panels on a phone, so focus inside them
  // moves to the handle that brings them back.
  collapseCallback() {
    const body = this.el.querySelector("#panel-sheet-body")
    const hasFocusInBody = body.contains(document.activeElement)
    this.setExpanded(false)

    if (hasFocusInBody) {
      this.handle.focus()
    }
  },

  setExpanded(expanded) {
    this.el.dataset.expanded = String(expanded)
    this.handle.setAttribute("aria-expanded", String(expanded))

    if (expanded) {
      this.handle.setAttribute("aria-label", COLLAPSE_LABEL)
    } else {
      this.handle.setAttribute("aria-label", EXPAND_LABEL)
    }

    this.writeInset()
  },

  // A click that ends a drag has done its work in the drag.
  toggleCallback() {
    if (this.dragged) {
      this.dragged = false
    } else {
      this.setExpanded(this.el.dataset.expanded !== "true")
    }
  },

  dragStart(event) {
    this.handle.setPointerCapture(event.pointerId)
    this.dragged = false
    this.drag = {startY: event.clientY, startHeight: this.el.getBoundingClientRect().height}
  },

  // The sheet follows the pointer, with its panels shown, so the rider
  // sees what the drag opens.
  dragMove(event) {
    if (this.drag === null) {
      return
    }

    const heightMax = window.innerHeight * DRAG_HEIGHT_FRACTION_MAX
    const height = this.drag.startHeight + this.drag.startY - event.clientY
    const boundedHeight = Math.min(Math.max(height, 0), heightMax)
    this.el.dataset.dragging = "true"
    this.el.style.height = `${Math.round(boundedHeight)}px`
  },

  dragEnd(event) {
    if (this.drag === null) {
      return
    }

    const outcome = dragOutcome({startY: this.drag.startY, endY: event.clientY})
    this.dragCancel()

    if (outcome !== DragOutcome.none) {
      this.dragged = true
      this.setExpanded(outcome === DragOutcome.expand)
    }
  },

  dragCancel() {
    this.drag = null
    this.el.removeAttribute("data-dragging")
    this.el.style.height = ""
  },

  // The bottom the sheet covers, which the map's attribution and notices
  // stand above.
  writeInset() {
    const {bottom} = sheetInsets()
    document.documentElement.style.setProperty(INSET_BOTTOM_PROPERTY, `${Math.round(bottom)}px`)
  },

  destroyed() {
    this.resizeObserver.disconnect()
    window.removeEventListener("resize", this.onResize)
    document.documentElement.style.removeProperty(INSET_BOTTOM_PROPERTY)
  }
}
