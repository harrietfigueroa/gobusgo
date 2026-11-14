// Reads the repository's shared fixtures from a case running in a browser.
// A browser has no file system, so each read goes through vitest's readFile
// command, which the test server answers; bytes travel as base64, since the
// command carries text.
// https://vitest.dev/api/browser/commands — checked 2026-11-14

import {server} from "vitest/browser"

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
