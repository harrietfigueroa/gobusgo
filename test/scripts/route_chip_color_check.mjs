// Checks the route chip text rule against every route color the agencies
// supply: each color's chip text reaches the 4.5:1 of WCAG 2.2 1.4.3. The
// colors are the fixture's, read from the stored routes-for-agency
// responses. A color the rule does not yet serve stands in `knownFailures`
// under the issue that fixes it, and an entry whose color passes fails the
// check, so a fix removes its entry. Run it with
// `node test/scripts/route_chip_color_check.mjs`; it exits non-zero and
// names every color that fails.

import {readFileSync} from "node:fs"
import {contrastRatio} from "../../assets/js/contrast.js"
import {chipTextColor} from "../../assets/js/route_chip_color.js"

const TEXT_CONTRAST_MIN = 4.5
const RATIO_DIGITS = 2

const knownFailures = new Map([
  ["#31859b", "GOB-302"],
  ["#ff0000", "GOB-302"]
])

const fixturePath = new URL("../fixtures/route_colors/route_colors.json", import.meta.url)
const fixture = JSON.parse(readFileSync(fixturePath, "utf8"))
const failures = []

for (const {color, routeCount} of fixture.colors) {
  const text = chipTextColor(color)
  const ratio = contrastRatio({foreground: text, background: color})
  const passes = ratio >= TEXT_CONTRAST_MIN
  const issue = knownFailures.get(color)
  const isKnown = issue !== undefined
  const passesKnown = passes && isKnown
  const failsUnknown = !passes && !isKnown

  if (passesKnown) {
    failures.push(`${color} passes at ${ratio.toFixed(RATIO_DIGITS)}:1; remove its known failure, ${issue}`)
  } else if (failsUnknown) {
    failures.push(`${color} (${routeCount} routes): ${text} text is ${ratio.toFixed(RATIO_DIGITS)}:1, under ${TEXT_CONTRAST_MIN}:1`)
  }
}

if (failures.length > 0) {
  console.error(failures.join("\n"))
  process.exit(1)
}

console.log(`route chip text: ${fixture.colors.length} route colors, ${knownFailures.size} known failures`)
