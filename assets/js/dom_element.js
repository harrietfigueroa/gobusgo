// The two elements the page's views build by hand most, a tag with a class
// and a text, and a button of that kind. Text goes in as a text node, never
// as HTML, since names come from outside the application.

/** A `tag` element of `className`, holding `text` where given. */
export function element({tag, className, text}) {
  const created = document.createElement(tag)
  created.className = className

  if (text !== undefined) {
    created.textContent = text
  }

  return created
}

/** A button of `className` that submits no form, holding `text` where given. */
export function button({className, text}) {
  const created = element({tag: "button", className, text})
  created.type = "button"
  return created
}
