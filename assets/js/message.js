// A status message as two lines: a bold headline that states the state, and
// a muted caption with the next step or the detail. The headline ends in a
// visually hidden full stop, so an element that reads the two, a live
// region among them, reads two sentences.

import {assertCondition} from "./assert.js"

const HEADLINE_CLASS_NAME = "message-headline"
const CAPTION_CLASS_NAME = "message-caption"
const HIDDEN_TEXT_CLASS_NAME = "sr-only"
// The space stands inside the hidden stop, so the headline and the caption
// read apart wherever whitespace between elements is dropped.
const HEADLINE_STOP = ". "

// The nodes of `message`, built as text nodes.
function messageNodes({headline, caption}) {
  assertCondition(headline !== "", "a message has a headline")
  assertCondition(caption !== "", "a message has a caption")
  const headlineElement = document.createElement("span")
  headlineElement.className = HEADLINE_CLASS_NAME
  headlineElement.append(headline)
  const stop = document.createElement("span")
  stop.className = HIDDEN_TEXT_CLASS_NAME
  stop.textContent = HEADLINE_STOP
  headlineElement.append(stop)
  const captionElement = document.createElement("span")
  captionElement.className = CAPTION_CLASS_NAME
  captionElement.textContent = caption
  return [headlineElement, captionElement]
}

/** Appends `message` to what `element` holds. */
export function appendMessage({element, message}) {
  const nodes = messageNodes(message)

  for (const node of nodes) {
    element.append(node)
  }
}

/** Writes `message` into `element` in place of what it held. */
export function writeMessage({element, message}) {
  element.replaceChildren()
  appendMessage({element, message})
}
