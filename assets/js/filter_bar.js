// The filter bar of a map page, following the WAI-ARIA combobox pattern:
// the text box is the combobox and the server's suggestions its listbox.
// The server renders the tokens and the suggestions and sends the events
// that add and remove a value; this hook holds which suggestion is active,
// which no render carries, and moves it from the keyboard.

import {CONNECTION_CHANGE_EVENT_NAME, connectionState} from "./connection_state.js"
import {ConnectionKind} from "./connection_rules.js"

const INPUT_SELECTOR = "[role=combobox]"
const OPTION_SELECTOR = "[role=option]"
const REMOVE_SELECTOR = ".filter-token-remove"
const BAR_SELECTOR = ".filter-bar"

// The key that tells one suggestion from another across renders.
function optionKey(option) {
  return `${option.getAttribute("phx-value-field")}/${option.getAttribute("phx-value-id")}`
}

// The index `findIndex` gives for no active option.
const NONE_INDEX = -1

// The index of the option ArrowDown, `isDown`, or ArrowUp makes active from
// `index` among `count` options, each wrapping around the list. From no
// active option ArrowDown reaches the first and ArrowUp the last.
function movedIndex({isDown, index, count}) {
  if (isDown) {
    return (index + 1) % count
  } else if (index <= 0) {
    return count - 1
  } else {
    return index - 1
  }
}

export const FilterBar = {
  mounted() {
    this.input = this.el.querySelector(INPUT_SELECTOR)
    this.listbox = document.getElementById(this.input.getAttribute("aria-controls"))
    this.activeKey = null

    this.input.addEventListener("keydown", (event) => { this.keydownCallback(event) })
    this.listbox.addEventListener("click", (event) => { this.optionClickCallback(event) })
    this.el.addEventListener("click", (event) => { this.barClickCallback(event) })
    this.onConnectionChange = () => { this.followConnection() }
    window.addEventListener(CONNECTION_CHANGE_EVENT_NAME, this.onConnectionChange)
    this.showActive()
    this.followConnection()
  },

  // A render resets every attribute this hook writes, so the active
  // suggestion is marked again, or none when the render no longer holds it,
  // and the bar is made read-only again while offline.
  updated() {
    this.showActive()
    this.followConnection()
  },

  destroyed() {
    window.removeEventListener(CONNECTION_CHANGE_EVENT_NAME, this.onConnectionChange)
  },

  // Offline the filter is read-only: the server answers no suggestion and
  // no change, so the text box and the tokens' remove buttons are disabled.
  followConnection() {
    const isReadOnly = connectionState().kind === ConnectionKind.offline
    this.input.disabled = isReadOnly

    for (const button of this.el.querySelectorAll(REMOVE_SELECTOR)) {
      button.disabled = isReadOnly
    }
  },

  options() {
    return Array.from(this.listbox.querySelectorAll(OPTION_SELECTOR))
  },

  activeIndex(options) {
    return options.findIndex((option) => optionKey(option) === this.activeKey)
  },

  showActive() {
    const options = this.options()
    const index = this.activeIndex(options)

    for (const [optionIndex, option] of options.entries()) {
      option.setAttribute("aria-selected", String(optionIndex === index))
    }

    if (index === NONE_INDEX) {
      this.activeKey = null
      this.input.removeAttribute("aria-activedescendant")
    } else {
      const active = options[index]
      this.input.setAttribute("aria-activedescendant", active.id)
      active.scrollIntoView({block: "nearest"})
    }
  },

  keydownCallback(event) {
    const options = this.options()

    switch (event.key) {
      case "ArrowDown":
      case "ArrowUp":
        this.moveActive({event, options})
        break
      case "Enter":
        this.chooseActive({event, options})
        break
      case "Escape":
        this.escape({event, options})
        break
      case "Backspace":
        this.removeLast()
        break
      default:
        break
    }
  },

  moveActive({event, options}) {
    if (options.length === 0) {
      return
    }

    event.preventDefault()
    const index = movedIndex({
      isDown: event.key === "ArrowDown",
      index: this.activeIndex(options),
      count: options.length
    })
    this.activeKey = optionKey(options[index])
    this.showActive()
  },

  // Enter with no active suggestion leaves the form to submit its text.
  chooseActive({event, options}) {
    const index = this.activeIndex(options)

    if (index === NONE_INDEX) {
      return
    }

    event.preventDefault()
    options[index].click()
  },

  // Escape with suggestions shown clears the text, which closes the list,
  // and stays inside the bar; with none it reaches the sheet, which
  // collapses.
  escape({event, options}) {
    if (options.length === 0) {
      return
    }

    event.stopPropagation()
    this.clearText()
  },

  // Backspace in an empty text box removes the last token.
  removeLast() {
    const isTextEmpty = this.input.value === ""

    if (!isTextEmpty) {
      return
    }

    const buttons = this.el.querySelectorAll(REMOVE_SELECTOR)

    if (buttons.length > 0) {
      buttons[buttons.length - 1].click()
    }
  },

  // The server adds the suggestion's value on the same click and clears the
  // text it keeps; the text box is focused and holds the text the rider
  // typed, which no render overwrites, so it is cleared here.
  optionClickCallback(event) {
    const option = event.target.closest(OPTION_SELECTOR)

    if (option === null) {
      return
    }

    this.activeKey = null
    this.input.value = ""
    this.input.focus()
  },

  // A token's button removes the token with the focus on it, so the focus
  // moves to the text box; a click elsewhere in the bar focuses it too.
  barClickCallback(event) {
    const isInBar = event.target.closest(BAR_SELECTOR) !== null

    if (isInBar) {
      this.input.focus()
    }
  },

  clearText() {
    this.activeKey = null
    this.input.value = ""
    this.input.dispatchEvent(new Event("input", {bubbles: true}))
  }
}
