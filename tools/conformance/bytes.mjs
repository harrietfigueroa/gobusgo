// Builds the bytes the refusal cases patch into a fixture. A browser has no
// `Buffer`, so hexadecimal text is parsed here.

import {assertCondition} from "../../assets/js/core/assert.js"

const HEX_RADIX = 16
const HEX_DIGITS_PER_BYTE = 2
const HEX_PATTERN = /^[0-9a-fA-F]*$/

/** The bytes `hex` spells, two hexadecimal digits a byte, and nothing else. */
export function hexBytes(hex) {
  const isWholeBytes = hex.length % HEX_DIGITS_PER_BYTE === 0
  assertCondition(isWholeBytes, `bytes: an odd count of digits in ${hex}`)
  assertCondition(HEX_PATTERN.test(hex), `bytes: ${hex} holds a character that is no hexadecimal digit`)
  const byteCount = Math.trunc(hex.length / HEX_DIGITS_PER_BYTE)
  const bytes = new Uint8Array(byteCount)

  for (let index = 0; index < byteCount; index++) {
    const start = index * HEX_DIGITS_PER_BYTE
    const digits = hex.slice(start, start + HEX_DIGITS_PER_BYTE)
    bytes[index] = Number.parseInt(digits, HEX_RADIX)
  }

  return bytes
}

/**
 * A copy of `bytes` with `edits` applied in order, as the shared refusal
 * fixtures write them: `{keep}` keeps the first bytes, `{cut}` drops the last,
 * `{append}` adds the bytes its hexadecimal text spells, and `{write: {offset,
 * hex}}` writes the bytes of `hex` at `offset`.
 */
export function editedBytes(bytes, edits) {
  let edited = bytes.slice(0)

  for (const edit of edits) {
    edited = appliedEdit(edited, edit)
  }

  return edited
}

function appliedEdit(bytes, edit) {
  if ("keep" in edit) {
    return bytes.slice(0, edit.keep)
  }

  if ("cut" in edit) {
    assertCondition(edit.cut <= bytes.length, `bytes: a cut of ${edit.cut} from ${bytes.length} bytes`)
    return bytes.slice(0, bytes.length - edit.cut)
  }

  if ("append" in edit) {
    const appended = hexBytes(edit.append)
    const out = new Uint8Array(bytes.length + appended.length)
    out.set(bytes, 0)
    out.set(appended, bytes.length)
    return out
  }

  assertCondition("write" in edit, `bytes: an edit of no known shape, ${JSON.stringify(edit)}`)
  const written = bytes.slice(0)
  written.set(hexBytes(edit.write.hex), edit.write.offset)
  return written
}
