// Reads the repository's shared fixtures from a case running in a browser.
// A browser has no file system, so each read goes through vitest's readFile
// command, which the test server answers; bytes travel as base64, since the
// command carries text.
// https://vitest.dev/api/browser/commands — checked 2026-11-14

import {server} from "vitest/browser"
import {assertCondition} from "../../assets/js/core/assert.js"

// The commands resolve a path against this package's directory.
const FIXTURES_PATH = "../../test/fixtures/"

/** The bytes of the fixture at `path` under `test/fixtures/`, as an `ArrayBuffer` of their own. */
export async function fixtureBytes(path) {
  const encoded = await server.commands.readFile(FIXTURES_PATH + path, {encoding: "base64"})
  const text = atob(encoded)
  const bytes = Uint8Array.from(text, charCode)
  return bytes.buffer
}

/** The parsed JSON of the fixture at `path` under `test/fixtures/`. */
export async function fixtureJson(path) {
  const text = await server.commands.readFile(FIXTURES_PATH + path, {encoding: "utf-8"})
  return JSON.parse(text)
}

function charCode(character) {
  return character.charCodeAt(0)
}

// The numbers JSON cannot write, by the strings a fixture writes them as.
const NUMBERS_BY_NAME = Object.freeze({
  NaN: Number.NaN,
  Infinity: Number.POSITIVE_INFINITY,
  "-Infinity": Number.NEGATIVE_INFINITY
})

/**
 * The number a fixture's `value` writes: a JSON number, or one of the strings
 * `NaN`, `Infinity`, and `-Infinity` for the numbers JSON cannot write.
 */
export function fixtureNumber(value) {
  if (typeof value === "number") {
    return value
  }
  const isNamedNumber = Object.hasOwn(NUMBERS_BY_NAME, value)
  assertCondition(isNamedNumber, `fixtures: ${value} stands for no number`)
  return NUMBERS_BY_NAME[value]
}
