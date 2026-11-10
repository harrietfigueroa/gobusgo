// Checks assets/css/app.css against the visual rules of WCAG 2.2 that a
// stylesheet alone decides, in the light and the dark theme:
//
// - text on its fill reaches 4.5:1 (1.4.3), and a control's boundary, a
//   state's mark, and a focus ring reach 3:1 against what they stand on
//   (1.4.11), for each pair the page draws from the themes' custom
//   properties;
// - each rule that sets a transition or an animation has a rule for the
//   same selector under `prefers-reduced-motion: reduce` (2.3.3);
// - each target-size custom property reaches 24px (2.5.8), and each hit
//   size meant for a finger reaches 44px;
// - each mark that forced colors removes has a rule for the same selector
//   under `forced-colors: active`: a state drawn by its fill alone, an icon
//   drawn as a background image, an icon recolored by a filter, and a state
//   that shows a border its base draws transparent.
//
// A failure the page has not yet fixed stands in `knownFailures` under the
// issue that fixes it, and an entry that no longer fails fails the check,
// so a fix removes its entry. Run it with
// `node test/scripts/css_accessibility_check.mjs`; it exits non-zero and
// names every failure.

import {readFileSync} from "node:fs"
import {assertCondition} from "../../assets/js/assert.js"
import {contrastRatio} from "../../assets/js/math/color_contrast.js"

const TEXT_CONTRAST_MIN = 4.5
const NON_TEXT_CONTRAST_MIN = 3
const TARGET_SIZE_PX_MIN = 24
const FINGER_TARGET_SIZE_PX_MIN = 44
const RATIO_DIGITS = 2
const HEX_RADIX = 16
const HEX_CHANNEL_DIGIT_COUNT = 2
const LIGHT_SELECTOR = ":root"
const DARK_SELECTOR = ':root[data-theme="dark"]'
const REDUCED_MOTION_MEDIA = "@media (prefers-reduced-motion: reduce)"
const FORCED_COLORS_MEDIA = "@media (forced-colors: active)"
const QUOTES = ["\"", "'"]
const COMMENT_PATTERN =/\/\*[\s\S]*?\*\//g
const WHITESPACE_PATTERN = /\s+/g
const REFERENCE_PATTERN = /^var\((--[\w-]+)\)$/
const LONG_HEX_PATTERN = /^#[0-9a-f]{6}$/i
const SHORT_HEX_PATTERN = /^#[0-9a-f]{3}$/i
const RGB_PATTERN = /^rgb\((\d+) (\d+) (\d+)\)$/
const PIXELS_PATTERN = /^(\d+(?:\.\d+)?)px$/
// A rule draws a state when one of its selectors names an attribute,
// pseudo-class, or class that a script or the rider sets.
const STATE_PATTERN = /\[aria-(selected|pressed|checked|current)="true"\]|:has\(:checked\)/

const PairKind = Object.freeze({text: "text", nonText: "nonText"})
const MarkKind = Object.freeze({
  fill: "fill",
  backgroundImage: "background image",
  filter: "filter",
  transparentBorder: "transparent border"
})

// Each foreground custom property the page draws on a fill custom property.
const pairs = [
  {kind: PairKind.text, foreground: "--panel-sheet-text-color", background: "--surface-fill"},
  {kind: PairKind.text, foreground: "--panel-sheet-text-color", background: "--panel-detail-action-fill"},
  {kind: PairKind.text, foreground: "--panel-sheet-text-color", background: "--filter-bar-fill"},
  {kind: PairKind.text, foreground: "--panel-sheet-text-color", background: "--filter-suggestion-active-fill"},
  {kind: PairKind.text, foreground: "--panel-sheet-text-color", background: "--theme-option-checked-fill"},
  {kind: PairKind.text, foreground: "--panel-sheet-text-color", background: "--panel-sheet-chip-fill"},
  {kind: PairKind.text, foreground: "--connection-signal-age-color", background: "--surface-fill"},
  {kind: PairKind.text, foreground: "--filter-kind-color", background: "--surface-fill"},
  {kind: PairKind.text, foreground: "--filter-kind-color", background: "--panel-detail-action-fill"},
  {kind: PairKind.text, foreground: "--filter-kind-color", background: "--panel-sheet-chip-fill"},
  {kind: PairKind.text, foreground: "--filter-kind-active-color", background: "--filter-suggestion-active-fill"},
  {kind: PairKind.text, foreground: "--popup-alert-color", background: "--surface-fill"},
  {kind: PairKind.text, foreground: "--panel-sheet-selected-color", background: "--surface-fill"},
  {kind: PairKind.text, foreground: "--panel-sheet-selected-color", background: "--panel-detail-action-fill"},
  {kind: PairKind.text, foreground: "--panel-sheet-selected-color", background: "--panel-detail-action-pressed-fill"},
  {kind: PairKind.text, foreground: "--panel-sheet-badge-color", background: "--panel-sheet-badge-fill"},
  {kind: PairKind.text, foreground: "--panel-sheet-badge-color", background: "--panel-sheet-alert-badge-fill"},
  {kind: PairKind.text, foreground: "--panel-sheet-filter-badge-color", background: "--surface-border-color"},
  {kind: PairKind.text, foreground: "--muted-text-color", background: "--surface-fill"},
  {kind: PairKind.text, foreground: "--route-chip-count-color", background: "--route-chip-count-fill"},
  {kind: PairKind.nonText, foreground: "--surface-border-color", background: "--surface-fill"},
  {kind: PairKind.nonText, foreground: "--surface-border-color", background: "--panel-detail-action-fill"},
  {kind: PairKind.nonText, foreground: "--panel-sheet-grip-color", background: "--surface-fill"},
  {kind: PairKind.nonText, foreground: "--close-button-fill", background: "--surface-fill"},
  {kind: PairKind.nonText, foreground: "--close-button-focus-color", background: "--surface-fill"},
  {kind: PairKind.nonText, foreground: "--close-button-focus-color", background: "--panel-detail-action-fill"}
]

// The target-size custom properties, each with the size it must reach.
const targetSizes = [
  {property: "--close-button-size", pxMin: TARGET_SIZE_PX_MIN},
  {property: "--popup-alert-hit-size", pxMin: TARGET_SIZE_PX_MIN},
  {property: "--filter-token-height", pxMin: TARGET_SIZE_PX_MIN},
  {property: "--inline-target-size", pxMin: TARGET_SIZE_PX_MIN},
  {property: "--close-button-hit-size", pxMin: FINGER_TARGET_SIZE_PX_MIN},
  {property: "--map-control-size", pxMin: FINGER_TARGET_SIZE_PX_MIN},
  {property: "--theme-option-height", pxMin: FINGER_TARGET_SIZE_PX_MIN},
  {property: "--filter-bar-height-min", pxMin: FINGER_TARGET_SIZE_PX_MIN},
  {property: "--filter-suggestion-height-min", pxMin: FINGER_TARGET_SIZE_PX_MIN}
]

const fillNames = ["background-color", "background"]
const markNames = ["border", "border-color", "border-bottom", "border-bottom-color", "border-width", "outline", "box-shadow", "font-weight", "text-decoration"]
const shownBorderNames = ["border-bottom-color", "border-color"]

const knownFailures = new Map([
])

// The stylesheet as a list of rules, each with its selectors, its
// declarations, and the at-rules it stands inside. A rule's body holds no
// braces, which every rule of app.css keeps.
function parseRules(css) {
  const source = css.replace(COMMENT_PATTERN, "")
  const rules = []
  const atRuleStack = []
  let start = 0
  let depth = 0
  let index = 0

  while (index < source.length) {
    const character = source[index]

    if (character === "{") {
      const prelude = source.slice(start, index).trim()

      if (prelude.startsWith("@")) {
        atRuleStack.push({prelude, depth})
        depth += 1
        start = index + 1
      } else {
        const close = source.indexOf("}", index)
        assertCondition(close > index, `a rule's body closes, at: ${prelude}`)
        const body = source.slice(index + 1, close)
        const media = Array.from(atRuleStack, atRulePrelude)
        rules.push({selectors: splitSelectors(prelude), declarations: parseDeclarations(body), media})
        index = close
        start = close + 1
      }
    } else if (character === "}") {
      depth -= 1
      atRuleStack.pop()
      start = index + 1
    } else if (character === ";") {
      // A statement such as @import or @source ends here.
      start = index + 1
    }

    index += 1
  }

  return rules
}

function atRulePrelude(entry) {
  return entry.prelude
}

function splitSelectors(prelude) {
  const selectors = prelude.split(",")
  return Array.from(selectors, normalizeSelector)
}

function normalizeSelector(selector) {
  const trimmed = selector.trim()
  return trimmed.replace(WHITESPACE_PATTERN, " ")
}

// The declarations of a rule's body as name-value pairs. A value's
// parentheses and quotes may hold semicolons.
function parseDeclarations(body) {
  const declarations = []
  let current = ""
  let parenthesisDepth = 0
  let quote = ""

  for (const character of body) {
    const isOutside = quote === "" && parenthesisDepth === 0
    const ends = isOutside && character === ";"

    if (ends) {
      pushDeclaration({declarations, text: current})
      current = ""
      continue
    }

    if (quote !== "") {
      if (character === quote) {
        quote = ""
      }
    } else if (QUOTES.includes(character)) {
      quote = character
    } else if (character === "(") {
      parenthesisDepth += 1
    } else if (character === ")") {
      parenthesisDepth -= 1
    }

    current += character
  }

  pushDeclaration({declarations, text: current})
  return declarations
}

function pushDeclaration({declarations, text}) {
  const colon = text.indexOf(":")

  if (colon > 0) {
    declarations.push({name: text.slice(0, colon).trim(), value: text.slice(colon + 1).trim()})
  }
}

function isThemeRule({rule, selector}) {
  const isTopLevel = rule.media.length === 0
  const isLone = rule.selectors.length === 1
  const isTopLevelLone = isTopLevel && isLone
  const namesTheme = isTopLevelLone && rule.selectors[0] === selector
  return namesTheme
}

function customProperties({rules, selector}) {
  const properties = new Map()

  for (const rule of rules) {
    if (isThemeRule({rule, selector})) {
      for (const {name, value} of rule.declarations) {
        properties.set(name, value)
      }
    }
  }

  return properties
}

// A custom property's color as `#rrggbb`, following a value that names
// another custom property of the theme.
function resolveColor({properties, property}) {
  const value = properties.get(property)
  assertCondition(value !== undefined, `the theme defines ${property}`)
  const reference = value.match(REFERENCE_PATTERN)

  if (reference === null) {
    return hexColor({property, value})
  } else {
    return resolveColor({properties, property: reference[1]})
  }
}

function hexColor({property, value}) {
  if (LONG_HEX_PATTERN.test(value)) {
    return value.toLowerCase()
  }

  if (SHORT_HEX_PATTERN.test(value)) {
    const digits = Array.from(value.slice(1), doubledDigit)
    return `#${digits.join("")}`.toLowerCase()
  }

  const rgb = value.match(RGB_PATTERN)
  assertCondition(rgb !== null, `${property} is an opaque color, got: ${value}`)
  const channels = Array.from(rgb.slice(1), channelHex)
  return `#${channels.join("")}`
}

function doubledDigit(digit) {
  return `${digit}${digit}`
}

function channelHex(channel) {
  const digits = Number(channel).toString(HEX_RADIX)
  return digits.padStart(HEX_CHANNEL_DIGIT_COUNT, "0")
}

function contrastFailures({themes}) {
  const failures = []

  for (const {name, properties} of themes) {
    for (const pair of pairs) {
      const foreground = resolveColor({properties, property: pair.foreground})
      const background = resolveColor({properties, property: pair.background})
      const ratio = contrastRatio({foreground, background})
      let ratioMin = NON_TEXT_CONTRAST_MIN

      if (pair.kind === PairKind.text) {
        ratioMin = TEXT_CONTRAST_MIN
      }

      if (ratio < ratioMin) {
        failures.push({key: `contrast ${name} ${pair.foreground} on ${pair.background}`, detail: `${foreground} on ${background} is ${ratio.toFixed(RATIO_DIGITS)}:1, under ${ratioMin}:1`})
      }
    }
  }

  return failures
}

function selectorsUnder({rules, media}) {
  const selectors = new Set()

  for (const rule of rules) {
    if (rule.media.includes(media)) {
      for (const selector of rule.selectors) {
        selectors.add(selector)
      }
    }
  }

  return selectors
}

function isMotionDeclaration({name, value}) {
  const isTransition = name.startsWith("transition")
  const isMotion = isTransition || name.startsWith("animation")
  const moves = isMotion && value !== "none"
  return moves
}

function motionFailures({rules}) {
  const covered = selectorsUnder({rules, media: REDUCED_MOTION_MEDIA})
  const failures = []

  for (const rule of rules) {
    const moves = rule.declarations.some(isMotionDeclaration)
    const needsOverride = moves && !rule.media.includes(REDUCED_MOTION_MEDIA)

    if (needsOverride) {
      for (const selector of rule.selectors) {
        if (!covered.has(selector)) {
          failures.push({key: `reduced motion ${selector}`, detail: `sets a transition or animation with no ${REDUCED_MOTION_MEDIA} rule for it`})
        }
      }
    }
  }

  return failures
}

function pixels({properties, property}) {
  const value = properties.get(property)
  assertCondition(value !== undefined, `the theme defines ${property}`)
  const match = value.match(PIXELS_PATTERN)
  assertCondition(match !== null, `${property} is a size in px, got: ${value}`)
  return Number(match[1])
}

function targetSizeFailures({properties}) {
  const failures = []

  for (const {property, pxMin} of targetSizes) {
    const size = pixels({properties, property})

    if (size < pxMin) {
      failures.push({key: `target size ${property}`, detail: `${size}px, under ${pxMin}px`})
    }
  }

  return failures
}

function declares({rule, names}) {
  for (const declaration of rule.declarations) {
    if (names.includes(declaration.name)) {
      return true
    }
  }

  return false
}

function isTransparentBorder(declaration) {
  const isBorder = declaration.name.startsWith("border")
  const isTransparent = isBorder && declaration.value.includes("transparent")
  return isTransparent
}

function isBackgroundImage(declaration) {
  const isBackground = declaration.name === "background"
  const hasImage = isBackground && declaration.value.includes("url(")
  return hasImage
}

function isFilter(declaration) {
  const isFilterName = declaration.name === "filter"
  const recolors = isFilterName && declaration.value !== "none"
  return recolors
}

function transparentBorderBases(rules) {
  const bases = []

  for (const rule of rules) {
    if (rule.declarations.some(isTransparentBorder)) {
      for (const selector of rule.selectors) {
        bases.push(selector)
      }
    }
  }

  return bases
}

function startsWithAny({selector, bases}) {
  for (const base of bases) {
    if (selector.startsWith(base)) {
      return true
    }
  }

  return false
}

// The kinds of mark that forced colors removes from `selector`, drawn by
// `rule`.
function selectorMarks({rule, selector, bases}) {
  const kinds = []
  const isState = STATE_PATTERN.test(selector)
  const drawsFill = isState && declares({rule, names: fillNames})
  const fillAlone = drawsFill && !declares({rule, names: markNames})
  const showsBorder = isState && declares({rule, names: shownBorderNames})
  const showsTransparentBorder = showsBorder && startsWithAny({selector, bases})

  if (fillAlone) {
    kinds.push(MarkKind.fill)
  }
  if (rule.declarations.some(isBackgroundImage)) {
    kinds.push(MarkKind.backgroundImage)
  }
  if (rule.declarations.some(isFilter)) {
    kinds.push(MarkKind.filter)
  }
  if (showsTransparentBorder) {
    kinds.push(MarkKind.transparentBorder)
  }

  return kinds
}

function forcedColorsFailures({rules}) {
  const covered = selectorsUnder({rules, media: FORCED_COLORS_MEDIA})
  const bases = transparentBorderBases(rules)
  const failures = []
  const seen = new Set()

  for (const rule of rules) {
    if (rule.media.includes(FORCED_COLORS_MEDIA)) {
      continue
    }

    for (const selector of rule.selectors) {
      for (const kind of selectorMarks({rule, selector, bases})) {
        const key = `forced colors ${kind} ${selector}`
        const isNew = !covered.has(selector) && !seen.has(key)

        if (isNew) {
          seen.add(key)
          failures.push({key, detail: `has no ${FORCED_COLORS_MEDIA} rule for it`})
        }
      }
    }
  }

  return failures
}

function failureKey(failure) {
  return failure.key
}

const cssPath = new URL("../../assets/css/app.css", import.meta.url)
const css = readFileSync(cssPath, "utf8")
const rules = parseRules(css)
const lightProperties = customProperties({rules, selector: LIGHT_SELECTOR})
const darkProperties = new Map(lightProperties)

for (const [name, value] of customProperties({rules, selector: DARK_SELECTOR})) {
  darkProperties.set(name, value)
}

const themes = [
  {name: "light", properties: lightProperties},
  {name: "dark", properties: darkProperties}
]

const found = []
const failureGroups = [
  contrastFailures({themes}),
  motionFailures({rules}),
  targetSizeFailures({properties: lightProperties}),
  forcedColorsFailures({rules})
]

for (const group of failureGroups) {
  for (const failure of group) {
    found.push(failure)
  }
}

const foundKeyList = Array.from(found, failureKey)
const foundKeys = new Set(foundKeyList)
const messages = []

for (const failure of found) {
  if (!knownFailures.has(failure.key)) {
    messages.push(`${failure.key}: ${failure.detail}`)
  }
}

for (const [key, issue] of knownFailures) {
  if (!foundKeys.has(key)) {
    messages.push(`${key} passes; remove its known failure, ${issue}`)
  }
}

if (messages.length > 0) {
  console.error(messages.join("\n"))
  process.exit(1)
}

console.log(`app.css: ${pairs.length} pairs in ${themes.length} themes, ${targetSizes.length} target sizes, ${knownFailures.size} known failures`)
