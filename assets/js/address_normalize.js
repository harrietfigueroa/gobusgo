// The normalization of street addresses that the index build and the search
// share, so a name a rider types and a name a county publishes reach the same
// key. Everything here is pure.
//
// A street is four parts: a prefix directional, a name, a type, and a suffix
// directional, each in the USPS abbreviation of Publication 28 where it has
// one. A numbered name is written as its digits with the ordinal suffix the
// number takes ("12TH", "1ST", "22ND"), whether it was typed as "12", "12th",
// or "twelfth".

import {assertCondition} from "./assert.js"

const DIRECTIONS = {
  N: "N", NORTH: "N", S: "S", SOUTH: "S", E: "E", EAST: "E", W: "W", WEST: "W",
  NE: "NE", NORTHEAST: "NE", NW: "NW", NORTHWEST: "NW",
  SE: "SE", SOUTHEAST: "SE", SW: "SW", SOUTHWEST: "SW",
}

const COMPOUND_DIRECTIONS = {
  "NORTH EAST": "NE", "NORTH WEST": "NW", "SOUTH EAST": "SE", "SOUTH WEST": "SW",
}

// USPS Publication 28, appendix C1, for the types the three counties use.
const STREET_TYPES = {
  ALLEY: "ALY", ALY: "ALY", AVENUE: "AVE", AVE: "AVE", AV: "AVE", AVEN: "AVE", AVN: "AVE",
  BOULEVARD: "BLVD", BLVD: "BLVD", BL: "BLVD", CIRCLE: "CIR", CIR: "CIR",
  COURT: "CT", CT: "CT", CRESCENT: "CRES", CRES: "CRES", CREST: "CRST", CRST: "CRST",
  DRIVE: "DR", DR: "DR", EXPRESSWAY: "EXPY", EXPY: "EXPY", FREEWAY: "FWY", FWY: "FWY",
  HIGHWAY: "HWY", HWY: "HWY", KEY: "KY", KY: "KY", LANE: "LN", LN: "LN", LOOP: "LOOP",
  MALL: "MALL", PARKWAY: "PKWY", PKWY: "PKWY", PKY: "PKWY", PLACE: "PL", PL: "PL",
  POINT: "PT", PT: "PT", ROAD: "RD", RD: "RD", ROW: "ROW", SQUARE: "SQ", SQ: "SQ",
  STREET: "ST", ST: "ST", STR: "ST", TERRACE: "TER", TER: "TER", TRAIL: "TRL", TRL: "TRL",
  WALK: "WALK", WAY: "WAY", WY: "WAY", VIEW: "VW", VW: "VW",
  PARK: "PARK", PLAZA: "PLZ", PLZ: "PLZ", TUNNEL: "TUNL", TUNL: "TUNL", VISTA: "VIS", VIS: "VIS",
  RUN: "RUN", PATH: "PATH", RIDGE: "RDG", RDG: "RDG", COVE: "CV", CV: "CV",
  EXTENSION: "EXT", EXT: "EXT", BRIDGE: "BRG", BRG: "BRG", CENTER: "CTR", CTR: "CTR",
  RANCH: "RNCH", RNCH: "RNCH", ROUTE: "RTE", RTE: "RTE",
  LP: "LOOP",
}

// Pierce County's "112TH ST CT E": a court, place, or loop off a numbered
// street or avenue, whose type is the two words.
const COMPOUND_TYPE_FIRSTS = new Set(["ST", "AVE", "LN"])
const COMPOUND_TYPE_SECONDS = new Set(["CT", "PL", "LOOP", "CIR", "RD"])

const ORDINAL_WORDS = {
  FIRST: 1, SECOND: 2, THIRD: 3, FOURTH: 4, FIFTH: 5, SIXTH: 6, SEVENTH: 7, EIGHTH: 8,
  NINTH: 9, TENTH: 10, ELEVENTH: 11, TWELFTH: 12, THIRTEENTH: 13, FOURTEENTH: 14,
  FIFTEENTH: 15, SIXTEENTH: 16, SEVENTEENTH: 17, EIGHTEENTH: 18, NINETEENTH: 19,
  TWENTIETH: 20, THIRTIETH: 30, FORTIETH: 40, FIFTIETH: 50, SIXTIETH: 60,
  SEVENTIETH: 70, EIGHTIETH: 80, NINETIETH: 90, HUNDREDTH: 100,
}

const UNIT_DESIGNATORS = new Set(["APT", "APARTMENT", "UNIT", "STE", "SUITE", "BLDG", "BUILDING", "FL", "FLOOR", "RM", "ROOM", "SPC", "SPACE", "LOT", "#", "NO"])
const INTERSECTION_WORDS = new Set(["&", "AND", "AT", "@", "/"])
const ORDINAL_PATTERN = /^(\d{1,9})(ST|ND|RD|TH)?$/
const HOUSE_NUMBER_PATTERN = /^(\d{1,9})([A-Z])?$/
const ZIP_PATTERN = /^\d{5}$/
const TEEN_MIN = 11
const TEEN_MAX = 13
const DECIMAL_BASE = 10
const HUNDRED = 100
const TOKEN_COUNT_MAX = 24
const ORDINAL_SUFFIXES = {1: "ST", 2: "ND", 3: "RD"}
const DIRECTION_PAIR_LENGTH = 2
const TOKENS_AFTER_DIRECTION_PAIR_MIN = 2
const ADDRESS_TOKEN_COUNT_MIN = 2
const LOCALITY_DROPPED_TOKENS = new Set([",", "WA", "WASHINGTON"])

function ordinalSuffix(number) {
  const lastTwo = number % HUNDRED
  const isTeen = lastTwo >= TEEN_MIN && lastTwo <= TEEN_MAX
  if (isTeen) {
    return "TH"
  }
  const last = number % DECIMAL_BASE
  const suffix = ORDINAL_SUFFIXES[last]
  if (suffix === undefined) {
    return "TH"
  }
  return suffix
}

/** A name token as its ordinal ("12" and "12TH" and "TWELFTH" are "12TH"), or the token unchanged. */
export function ordinalToken(token) {
  const fromWord = ORDINAL_WORDS[token]
  if (fromWord !== undefined) {
    return String(fromWord) + ordinalSuffix(fromWord)
  }
  const match = ORDINAL_PATTERN.exec(token)
  if (match === null) {
    return token
  }
  const number = Number.parseInt(match[1], DECIMAL_BASE)
  return String(number) + ordinalSuffix(number)
}

/** The tokens of `text`: upper case, punctuation dropped but `&`, `/`, `@`, and `#` kept as tokens of their own. */
export function tokenize(text) {
  assertCondition(typeof text === "string", "address normalize: the text is not a string: " + typeof text)
  const spaced = text.toUpperCase().replace(/[&/@#,]/g, " $& ").replace(/[.'’"()]/g, "").replace(/-/g, " ")
  const tokens = []
  for (const token of spaced.split(/\s+/)) {
    if (token === "") {
      continue
    }
    if (tokens.length === TOKEN_COUNT_MAX) {
      break
    }
    tokens.push(token)
  }
  return tokens
}

// "NORTH EAST 45TH STREET" is NE 45TH ST, while "NORTH WEST AVENUE" is N WEST
// AVE: a two-word directional is merged only where two tokens follow it.
function mergeCompoundDirections(tokens) {
  const merged = []
  for (let index = 0; index < tokens.length; index++) {
    const hasTwoAfterPair = index + DIRECTION_PAIR_LENGTH + TOKENS_AFTER_DIRECTION_PAIR_MIN <= tokens.length
    if (hasTwoAfterPair) {
      const compound = COMPOUND_DIRECTIONS[tokens[index] + " " + tokens[index + 1]]
      if (compound !== undefined) {
        merged.push(compound)
        index++
        continue
      }
    }
    merged.push(tokens[index])
  }
  return merged
}

/**
 * The four parts of a street from its tokens, in the order a sign or a county
 * writes them: a suffix directional and a type are read from the end and a
 * prefix directional from the start, each only while a name token remains.
 */
export function parseStreet(rawTokens) {
  assertCondition(Array.isArray(rawTokens), "address normalize: the street tokens are not an array")
  const tokens = mergeCompoundDirections(rawTokens)
  let first = 0
  let last = tokens.length - 1
  let preDirection = ""
  let type = ""
  let sufDirection = ""

  const hasSuffixRoom = last - first >= 1
  if (hasSuffixRoom) {
    const direction = DIRECTIONS[tokens[last]]
    if (direction !== undefined) {
      sufDirection = direction
      last--
    }
  }
  const hasTypeRoom = last - first >= 1
  if (hasTypeRoom) {
    const streetType = STREET_TYPES[tokens[last]]
    if (streetType !== undefined) {
      type = streetType
      last--
    }
  }
  const hasCompoundTypeRoom = type !== "" && last - first >= 1
  if (hasCompoundTypeRoom) {
    const firstType = STREET_TYPES[tokens[last]]
    const isCompound = COMPOUND_TYPE_FIRSTS.has(firstType) && COMPOUND_TYPE_SECONDS.has(type)
    if (isCompound) {
      type = firstType + " " + type
      last--
    }
  }
  const hasPrefixRoom = last - first >= 1
  if (hasPrefixRoom) {
    const direction = DIRECTIONS[tokens[first]]
    if (direction !== undefined) {
      preDirection = direction
      first++
    }
  }

  const nameTokens = []
  for (let index = first; index <= last; index++) {
    nameTokens.push(ordinalToken(tokens[index]))
  }
  return {preDirection, name: nameTokens.join(" "), type, sufDirection}
}

/**
 * The street of a county's separate fields, joined into one line and parsed
 * as a typed street is, so a county that writes "WEST" in the name and a
 * rider who types "W" before it reach one street.
 */
export function streetFromFields({preDirection, name, type, sufDirection}) {
  const line = [preDirection, name, type, sufDirection].join(" ")
  return parseStreet(tokenize(line))
}

/** The one-line key of a street: its four parts, separated by spaces, empty parts left out. */
export function streetKey(street) {
  const parts = []
  for (const part of [street.preDirection, street.name, street.type, street.sufDirection]) {
    if (part !== "") {
      parts.push(part)
    }
  }
  return parts.join(" ")
}

function dropUnit(tokens) {
  const kept = []
  for (let index = 0; index < tokens.length; index++) {
    if (UNIT_DESIGNATORS.has(tokens[index])) {
      // The designator and the one token after it name the unit.
      index++
      continue
    }
    kept.push(tokens[index])
  }
  return kept
}

/**
 * What a rider typed, as one of three kinds: an address with a house number
 * and a street, an intersection of two streets, or a street alone. A unit or
 * suite is dropped; text after a comma is the locality, and a five-digit
 * token there or at the end is a ZIP code.
 */
export function parseQuery(text) {
  const tokens = tokenize(text)
  const commaIndex = tokens.indexOf(",")
  let streetTokens = tokens
  let localityTokens = []
  if (commaIndex >= 0) {
    streetTokens = tokens.slice(0, commaIndex)
    const afterComma = tokens.slice(commaIndex + 1)
    localityTokens = afterComma.filter(isLocalityToken)
  }
  let zip = ""
  const localityKept = []
  for (const token of localityTokens) {
    if (ZIP_PATTERN.test(token)) {
      zip = token
      continue
    }
    localityKept.push(token)
  }
  const kept = dropUnit(streetTokens)

  for (let index = 1; index < kept.length - 1; index++) {
    if (INTERSECTION_WORDS.has(kept[index])) {
      return {
        kind: "intersection",
        first: parseStreet(kept.slice(0, index)),
        second: parseStreet(kept.slice(index + 1)),
        locality: localityKept.join(" "),
        zip,
      }
    }
  }

  let firstToken = ""
  if (kept.length >= 1) {
    firstToken = kept[0]
  }
  const numberMatch = HOUSE_NUMBER_PATTERN.exec(firstToken)
  const hasStreetAfterNumber = numberMatch !== null && kept.length >= ADDRESS_TOKEN_COUNT_MIN
  if (hasStreetAfterNumber) {
    const [, digits, letter] = numberMatch
    let numberSuffix = ""
    if (letter !== undefined) {
      numberSuffix = letter
    }
    return {
      kind: "address",
      number: Number.parseInt(digits, DECIMAL_BASE),
      numberSuffix,
      street: parseStreet(kept.slice(1)),
      locality: localityKept.join(" "),
      zip,
    }
  }
  return {kind: "street", street: parseStreet(kept), locality: localityKept.join(" "), zip}
}

function isLocalityToken(token) {
  return !LOCALITY_DROPPED_TOKENS.has(token)
}
