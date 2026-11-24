// Writes the engine's expected file beside its hand-written fixtures, from
// them. Run it with `node test/scripts/routing_engine_fixtures.mjs` after a
// change to a hand-written fixture.

import {readFileSync, writeFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {engineCases} from "./routing_engine_cases.mjs"

const JSON_INDENT = 1
// A list of whole numbers JSON.stringify writes one number to a line.
const NUMBER_LIST_PATTERN = /\[\n *(-?\d+(?:,\n *-?\d+)*)\n *\]/g
const LIST_SEPARATOR_PATTERN = /,\n */g

const directory = fileURLToPath(new URL("../fixtures/routing/engine-v1/", import.meta.url))

function parsedFile(name) {
  const text = readFileSync(directory + name, "utf-8")
  return JSON.parse(text)
}

// A list of numbers on one line, so a case's columns read across.
function numberLine(_match, numbers) {
  const joined = numbers.replaceAll(LIST_SEPARATOR_PATTERN, ", ")
  return "[" + joined + "]"
}

const journeys = parsedFile("journeys.json")
const starts = parsedFile("starts.json")
const cases = engineCases({journeys, starts})
const text = JSON.stringify(cases, null, JSON_INDENT)
const compacted = text.replaceAll(NUMBER_LIST_PATTERN, numberLine)
writeFileSync(directory + "expected.json", compacted + "\n")
