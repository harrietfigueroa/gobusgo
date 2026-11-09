// Checks that the front end writes the strings it shows into the DOM as
// text. Route and stop names, headsigns, alert texts, and shared vehicle
// data come from agencies and providers, and an HTML sink such as
// `innerHTML` or MapLibre's `Popup.setHTML` would parse them as markup, so
// it reads every file under `assets/js/` and fails on any call that hands
// the DOM a string as HTML. Run it with `node test/scripts/dom_text_check.mjs`;
// it exits non-zero on the first file that holds one.
//
// https://maplibre.org/maplibre-gl-js/docs/API/classes/Popup/#sethtml — checked 2026-11-09

import {ok} from "node:assert/strict"
import {readdirSync, readFileSync} from "node:fs"

const sourceDirectory = new URL("../../assets/js/", import.meta.url)

const htmlSinkPatterns = [
  /\.innerHTML\b/,
  /\.outerHTML\b/,
  /\binsertAdjacentHTML\b/,
  /\.setHTML(Unsafe)?\(/,
  /\bcreateContextualFragment\b/,
  /\bDOMParser\b/,
  /\bdocument\.write(ln)?\(/,
  /\bsrcdoc\b/
]

function isScript(name) {
  return name.endsWith(".js") || name.endsWith(".mjs")
}

const names = readdirSync(sourceDirectory).filter(isScript)
ok(names.length > 0, "assets/js holds no script to read")

for (const name of names) {
  const text = readFileSync(new URL(name, sourceDirectory), "utf8")

  for (const pattern of htmlSinkPatterns) {
    ok(!pattern.test(text), `assets/js/${name} holds ${pattern}, which hands the DOM a string as HTML`)
  }
}

// A pattern that misses its sink would pass every file, so each one is
// shown a line that holds its sink.
const sinkSamples = [
  "popup.innerHTML = name",
  "row.outerHTML = name",
  "list.insertAdjacentHTML(\"beforeend\", name)",
  "popup.setHTML(name)",
  "element.setHTMLUnsafe(name)",
  "range.createContextualFragment(name)",
  "new DOMParser()",
  "document.write(name)",
  "frame.srcdoc = name"
]

for (const sample of sinkSamples) {
  const isMatched = htmlSinkPatterns.some((pattern) => pattern.test(sample))
  ok(isMatched, `no pattern matches the sink in ${JSON.stringify(sample)}`)
}

console.log(`DOM text check passed for ${names.length} files`)
