// The map control that stops following a bus: one text button in a control
// group, hidden while no bus is followed. Its `onAdd` and `onRemove` are the
// callbacks of a MapLibre control, and `render` writes the button's name and
// whether the group is hidden.

const GROUP_CLASSES = ["maplibregl-ctrl", "maplibregl-ctrl-group", "vehicle-follow-control"]
const BUTTON_CLASS = "vehicle-follow-stop"
const BUTTON_TEXT = "Stop following"

function createElement({tag, className}) {
  const element = document.createElement(tag)
  element.className = className
  return element
}

/** A stop control that calls `onStop` when its button is pressed. */
export function createStopControl({onStop}) {
  let group = null
  let button = null

  return {
    onAdd() {
      group = createElement({tag: "div", className: GROUP_CLASSES.join(" ")})
      button = createElement({tag: "button", className: BUTTON_CLASS})
      button.type = "button"
      button.textContent = BUTTON_TEXT
      button.addEventListener("click", onStop)
      group.hidden = true
      group.append(button)
      return group
    },

    onRemove() {
      button = null
      group = null
    },

    render({label, isHidden}) {
      if (button === null) {
        return
      }

      button.setAttribute("aria-label", label)
      group.hidden = isHidden
    },

    hasFocus() {
      return button !== null && document.activeElement === button
    }
  }
}
