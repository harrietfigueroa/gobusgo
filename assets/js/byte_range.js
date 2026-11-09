// The byte range a request asks for of a stored file, and the status and
// headers of the answer. Everything here is pure: it decides from a Range
// header's text and the file's length, and reads no body.
//
// One range is answered, in each of the three forms of RFC 9110: from a
// first to a last position, from a first position to the end, and the last
// bytes of a given count. A last position past the end reads to the end, a
// first position at or past the end, or a count of no bytes, cannot be
// satisfied, and any other header, several ranges or another unit included,
// is ignored and the whole file is answered.
// https://www.rfc-editor.org/rfc/rfc9110.html#name-byte-ranges — checked 2026-11-08
// https://www.rfc-editor.org/rfc/rfc9110.html#name-range — checked 2026-11-08

import {assertCondition, unreachable} from "./assert.js"

const SINGLE_RANGE_PATTERN = /^bytes=(\d*)-(\d*)$/
const PARTIAL_STATUS = 206
const UNSATISFIABLE_STATUS = 416

/** The kinds of a requested range: the whole file, a part of it, or a part it does not have. */
export const RangeKind = Object.freeze({whole: "whole", partial: "partial", unsatisfiable: "unsatisfiable"})

const WHOLE = Object.freeze({kind: RangeKind.whole})
const UNSATISFIABLE = Object.freeze({kind: RangeKind.unsatisfiable})

function partial({start, end}) {
  return {kind: RangeKind.partial, start, end}
}

// The range from `first` to `last`, either of which may be the empty text.
function rangeOf({first, last, total}) {
  const hasFirst = first !== ""
  const hasLast = last !== ""

  if (hasFirst) {
    const start = Number(first)
    const isSatisfiable = start < total

    if (!isSatisfiable) {
      return UNSATISFIABLE
    }

    if (!hasLast) {
      return partial({start, end: total - 1})
    }

    const end = Number(last)

    // A last position before the first makes the header invalid.
    if (end < start) {
      return WHOLE
    }

    return partial({start, end: Math.min(end, total - 1)})
  }

  if (!hasLast) {
    return WHOLE
  }

  const count = Number(last)
  const isEmptySuffix = count === 0

  if (isEmptySuffix) {
    return UNSATISFIABLE
  }

  return partial({start: Math.max(0, total - count), end: total - 1})
}

/**
 * The range that `header`, a request's Range header or null, asks for of a
 * file of `total` bytes: `{kind: RangeKind.partial, start, end}`, with both
 * positions inside the file and `end` inclusive, the whole file, or none.
 */
export function requestedRange({header, total}) {
  assertCondition(Number.isSafeInteger(total), "byte range: a file's length is not an integer: " + total)
  assertCondition(total >= 0, "byte range: a file's length is negative: " + total)

  if (header === null) {
    return WHOLE
  }

  const matched = SINGLE_RANGE_PATTERN.exec(header.trim())

  if (matched === null) {
    return WHOLE
  }

  const [, first, last] = matched
  const range = rangeOf({first, last, total})

  if (range.kind === RangeKind.partial) {
    assertCondition(range.start <= range.end, "byte range: a range ends before it starts: " + range.start + "-" + range.end)
    assertCondition(range.end < total, "byte range: a range ends past the file: " + range.end + " of " + total)
  }

  return range
}

function representationHeaders({etag, contentType}) {
  const headers = {"content-type": contentType}

  if (etag !== null) {
    headers.etag = etag
  }

  return headers
}

/**
 * The answer to `range` of a file of `total` bytes whose stored response
 * carried `etag`, or null, and `contentType`: its status, its headers, and
 * the part of the body it holds, from `sliceStart` up to and excluding
 * `sliceEnd`. A partial answer carries the stored ETag, which a PMTiles
 * reader compares with the one of the archive's header.
 * https://www.rfc-editor.org/rfc/rfc9110.html#name-206-partial-content — checked 2026-11-08
 * https://www.rfc-editor.org/rfc/rfc9110.html#name-416-range-not-satisfiable — checked 2026-11-08
 */
export function rangeAnswer({range, total, etag, contentType}) {
  switch (range.kind) {
    case RangeKind.whole: {
      const headers = {"accept-ranges": "bytes", "content-length": String(total), ...representationHeaders({etag, contentType})}
      return {status: 200, sliceStart: 0, sliceEnd: total, headers}
    }
    case RangeKind.partial: {
      const sliceEnd = range.end + 1
      const length = sliceEnd - range.start
      const contentRange = "bytes " + range.start + "-" + range.end + "/" + total
      const headers = {"accept-ranges": "bytes", "content-length": String(length), "content-range": contentRange, ...representationHeaders({etag, contentType})}
      return {status: PARTIAL_STATUS, sliceStart: range.start, sliceEnd, headers}
    }
    case RangeKind.unsatisfiable: {
      const headers = {"accept-ranges": "bytes", "content-length": "0", "content-range": "bytes */" + total}
      return {status: UNSATISFIABLE_STATUS, sliceStart: 0, sliceEnd: 0, headers}
    }
    default:
      return unreachable(range.kind, "byte range: a range of unknown kind")
  }
}
