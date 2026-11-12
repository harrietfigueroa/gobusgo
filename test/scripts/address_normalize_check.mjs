// Checks the address normalizer of the index build and the search as pure
// functions: every case of the shared normalizer fixture, which the Elixir
// tests of the same rules read too, must give the fixture's street, key,
// and parsed query. Run it with
// `node test/scripts/address_normalize_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {readFileSync} from "node:fs"
import {AssertionError} from "../../assets/js/core/assert.js"
import {ordinalToken, parseQuery, streetFromFields, streetKey, tokenize} from "../../assets/js/address_normalize.js"

const NOT_TEXT = 7
const SINGLE_CASE_COUNT = 2

const fixtureUrl = new URL("../fixtures/addresses/normalize.json", import.meta.url)
const {fields, queries} = JSON.parse(readFileSync(fixtureUrl, "utf8"))

for (const {input, street, key} of fields) {
  const actual = streetFromFields(input)
  deepStrictEqual(actual, street, "street of " + JSON.stringify(input))
  deepStrictEqual(streetKey(actual), key, "key of " + JSON.stringify(input))
}

for (const {text, parsed} of queries) {
  deepStrictEqual(parseQuery(text), parsed, "query " + JSON.stringify(text))
}

const ordinalCases = [
  ["1", "1ST"], ["2", "2ND"], ["3", "3RD"], ["4", "4TH"], ["11", "11TH"], ["12", "12TH"], ["13", "13TH"],
  ["21", "21ST"], ["22", "22ND"], ["101", "101ST"], ["111", "111TH"], ["112TH", "112TH"], ["TWELFTH", "12TH"],
  ["HUNDREDTH", "100TH"], ["MAIN", "MAIN"]
]
for (const [token, expected] of ordinalCases) {
  deepStrictEqual(ordinalToken(token), expected, "ordinal of " + token)
}

function tokenizeNumber() {
  return tokenize(NOT_TEXT)
}

deepStrictEqual(tokenize("Mt. Baker-Blvd, Apt #4"), ["MT", "BAKER", "BLVD", ",", "APT", "#", "4"])
throws(tokenizeNumber, AssertionError)

console.log("address_normalize_check: " + (fields.length + queries.length + ordinalCases.length + SINGLE_CASE_COUNT) + " cases passed")
