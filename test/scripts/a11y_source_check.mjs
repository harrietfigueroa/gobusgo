// Scans the front end's JavaScript for the patterns that break keyboard and
// screen reader use in the DOM it builds, which html-eslint never sees: a
// tabindex above 0, an `aria-haspopup` that promises a popup role the code
// never gives, and a click handler on an element built as a tag that a
// keyboard cannot reach. It first checks the scan against sources written
// out by hand, then scans assets/js/. Run it with
// `node test/scripts/a11y_source_check.mjs`; it exits non-zero on a finding
// that is not a known failure, and on a known failure that is gone.

import {deepStrictEqual} from "node:assert/strict"
import {readdirSync, readFileSync} from "node:fs"

const SOURCE_DIRECTORY = new URL("../../assets/js/", import.meta.url)

// The tags a keyboard reaches and a screen reader names as controls.
const INTERACTIVE_TAGS = new Set(["a", "button", "input", "select", "summary", "textarea"])

// The roles `aria-haspopup` may promise, and that the popup must then have.
// https://www.w3.org/TR/wai-aria-1.2/#aria-haspopup — checked 2026-11-09
const POPUP_ROLES = ["menu", "listbox", "tree", "grid", "dialog"]

const FindingKind = Object.freeze({
  positiveTabindex: "positive-tabindex",
  unmatchedPopup: "unmatched-popup",
  clickOnStaticTag: "click-on-static-tag"
})

// The findings still in assets/js/, each with the issue that fixes it, by
// file and kind. The scan must still find each, so the fix removes it.
const KNOWN_FAILURES = Object.freeze({})

const TABINDEX_PATTERNS = [
  /\.tabIndex\s*=\s*(\d+)/g,
  /setAttribute\(\s*"tabindex"\s*,\s*"(\d+)"\s*\)/g
]
const HASPOPUP_PATTERN = /setAttribute\(\s*"aria-haspopup"\s*,\s*"([a-z]+)"\s*\)/g
const CREATED_PATTERNS = [
  /(?:const|let)\s+(\w+)\s*=\s*document\.createElement\(\s*"([a-z0-9]+)"\s*\)/g,
  /(?:const|let)\s+(\w+)\s*=\s*element\(\s*\{\s*tag:\s*"([a-z0-9]+)"/g
]

function lineOf({source, index}) {
  return source.slice(0, index).split("\n").length
}

function positiveTabindexFindings(source) {
  const findings = []

  for (const pattern of TABINDEX_PATTERNS) {
    for (const match of source.matchAll(pattern)) {
      const value = Number(match[1])

      if (value > 0) {
        findings.push({kind: FindingKind.positiveTabindex, line: lineOf({source, index: match.index})})
      }
    }
  }

  return findings
}

// "true" promises a menu.
function promisedRole(value) {
  if (value === "true") {
    return "menu"
  }

  return value
}

function unmatchedPopupFindings(source) {
  const findings = []

  for (const match of source.matchAll(HASPOPUP_PATTERN)) {
    const role = promisedRole(match[1])
    const isNone = role === "false"
    const givesRole = source.includes(`"role", "${role}"`)
    const isKnownRole = POPUP_ROLES.includes(role)
    const isMatched = givesRole && isKnownRole
    const isUnmatched = !isNone && !isMatched

    if (isUnmatched) {
      findings.push({kind: FindingKind.unmatchedPopup, line: lineOf({source, index: match.index})})
    }
  }

  return findings
}

function clickOnStaticTagFindings(source) {
  const findings = []

  for (const pattern of CREATED_PATTERNS) {
    for (const match of source.matchAll(pattern)) {
      const [, name, tag] = match
      const isStatic = !INTERACTIVE_TAGS.has(tag)
      const hasClick = source.includes(`${name}.addEventListener("click"`)
      const hasRole = source.includes(`${name}.setAttribute("role"`)
      const hasTabindex = source.includes(`${name}.tabIndex = 0`)
      const isReachable = hasRole && hasTabindex
      const isUnreachable = hasClick && !isReachable
      const isFinding = isStatic && isUnreachable

      if (isFinding) {
        findings.push({kind: FindingKind.clickOnStaticTag, line: lineOf({source, index: match.index})})
      }
    }
  }

  return findings
}

/** Every finding in `source`, in the order of the kinds, then of the lines. */
export function findings(source) {
  return [
    ...positiveTabindexFindings(source),
    ...unmatchedPopupFindings(source),
    ...clickOnStaticTagFindings(source)
  ]
}

const cases = [
  {source: "button.tabIndex = 0\nother.tabIndex = -1", kinds: []},
  {source: "button.tabIndex = 2", kinds: [FindingKind.positiveTabindex]},
  {source: `field.setAttribute("tabindex", "1")`, kinds: [FindingKind.positiveTabindex]},
  {source: `field.setAttribute("aria-haspopup", "true")`, kinds: [FindingKind.unmatchedPopup]},
  {source: `field.setAttribute("aria-haspopup", "listbox")\nlist.setAttribute("role", "listbox")`, kinds: []},
  {source: `field.setAttribute("aria-haspopup", "dialog")`, kinds: [FindingKind.unmatchedPopup]},
  {source: `const row = document.createElement("div")\nrow.addEventListener("click", go)`, kinds: [FindingKind.clickOnStaticTag]},
  {source: `const row = element({tag: "li", className: "x"})\nrow.addEventListener("click", go)`, kinds: [FindingKind.clickOnStaticTag]},
  {source: `const row = document.createElement("button")\nrow.addEventListener("click", go)`, kinds: []},
  {source: `const row = document.createElement("div")\nrow.setAttribute("role", "button")\nrow.tabIndex = 0\nrow.addEventListener("click", go)`, kinds: []}
]

function kindOf(finding) {
  return finding.kind
}

for (const {source, kinds} of cases) {
  const caseFindings = findings(source)
  const caseKinds = Array.from(caseFindings, kindOf)
  deepStrictEqual(caseKinds, kinds, source)
}

// Every finding of assets/js/, by file and kind, with the line it is on.
const found = new Map()

for (const fileName of readdirSync(SOURCE_DIRECTORY)) {
  if (fileName.endsWith(".js")) {
    const source = readFileSync(new URL(fileName, SOURCE_DIRECTORY), "utf8")

    for (const finding of findings(source)) {
      found.set(`${fileName} ${finding.kind}`, `${fileName}:${finding.line} ${finding.kind}`)
    }
  }
}

const unknown = []

for (const [key, where] of found) {
  if (KNOWN_FAILURES[key] === undefined) {
    unknown.push(where)
  }
}

const fixed = []

for (const key of Object.keys(KNOWN_FAILURES)) {
  if (!found.has(key)) {
    fixed.push(key)
  }
}

deepStrictEqual(unknown, [], "findings that are not known failures")
deepStrictEqual(fixed, [], "known failures no longer found: remove them from KNOWN_FAILURES")
