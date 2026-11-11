// The trip strip's element: the chosen journey drawn above the sheet's tabs,
// written into the empty element the server renders and a patch leaves
// alone. The strip is one control named by its sentence, whose texts and bar
// are drawn for the eye; an End trip button stands beside it, and the next
// steps and an All steps button follow where the stylesheet has room. A
// write changes texts and attributes in place and sets no live region, so
// a countdown tick announces nothing and a focused control keeps its focus.

import {barElement} from "./journey_bar"
import {liveDot} from "./stop_arrivals"

const MAIN_LABEL_ATTRIBUTE = "aria-label"
const END_TEXT = "End trip"
const ALL_STEPS_TEXT = "All steps"

function create({tag, className, text}) {
  const created = document.createElement(tag)
  created.className = className

  if (text !== undefined) {
    created.textContent = text
  }

  return created
}

function createButton({className, text}) {
  const created = create({tag: "button", className, text})
  created.type = "button"
  return created
}

function buildMain() {
  const main = createButton({className: "trip-strip-main"})
  const heading = create({tag: "span", className: "trip-strip-heading"})
  const lead = create({tag: "strong", className: "trip-strip-lead"})
  const arrive = create({tag: "span", className: "trip-strip-arrive"})
  heading.append(lead, arrive)
  const barSlot = create({tag: "span", className: "trip-strip-bar"})
  const detail = create({tag: "span", className: "trip-strip-detail"})
  const dotSlot = create({tag: "span", className: "trip-strip-dot"})
  const status = create({tag: "span", className: "trip-strip-status"})
  const step = create({tag: "span", className: "trip-strip-step"})
  detail.append(dotSlot, status, step)
  main.append(heading, barSlot, detail)
  return {main, lead, arrive, barSlot, dotSlot, status, step}
}

/**
 * The view of the strip inside `host`: it shows a `tripStrip` answer, hides
 * the strip from the page and from assistive technology, and says whether a
 * node is inside it. `onOpen` is called for a press of the strip or of All
 * steps, `onEnd` for End trip.
 */
export function createStripView({host, onOpen, onEnd}) {
  const parts = buildMain()
  const endButton = createButton({className: "trip-strip-end", text: END_TEXT})
  const stepList = create({tag: "ol", className: "trip-strip-steps"})
  const allSteps = createButton({className: "trip-strip-all", text: ALL_STEPS_TEXT})
  const more = create({tag: "div", className: "trip-strip-more"})
  more.append(stepList, allSteps)
  const top = create({tag: "div", className: "trip-strip-top"})
  top.append(parts.main, endButton)
  host.replaceChildren(top, more)
  parts.main.addEventListener("click", () => { onOpen() })
  allSteps.addEventListener("click", () => { onOpen() })
  endButton.addEventListener("click", () => { onEnd() })

  return {
    write(strip) {
      parts.main.setAttribute(MAIN_LABEL_ATTRIBUTE, strip.sentence)
      parts.lead.textContent = strip.leadText
      parts.arrive.textContent = strip.arriveText
      parts.barSlot.replaceChildren(barElement(strip.segments))
      parts.status.textContent = strip.statusText
      parts.step.textContent = strip.firstStepText

      if (strip.isLive) {
        parts.dotSlot.replaceChildren(liveDot())
      } else {
        parts.dotSlot.replaceChildren()
      }

      const items = []

      for (const text of strip.nextStepTexts) {
        items.push(create({tag: "li", className: "trip-strip-next", text}))
      }

      stepList.replaceChildren()

      for (const item of items) {
        stepList.append(item)
      }

      host.toggleAttribute("hidden", false)
    },

    hide() {
      host.toggleAttribute("hidden", true)
    },

    contains(node) {
      return node !== null && host.contains(node)
    },
  }
}
