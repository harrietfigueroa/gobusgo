// Checks how the service worker answers from the saved offline bundle,
// against cases written out by hand: the byte range a Range header asks for
// and the status and headers of its answer, the cache-first answer of a
// saved file with a stored body read once, and the network-first answer of
// the routing manifest with its fallbacks. The caches and the network are
// functions over values held in memory. Run it with
// `node test/scripts/saved_files_check.mjs`; it exits non-zero on the first
// case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {RangeKind, rangeAnswer, requestedRange} from "../../assets/js/byte_range.js"
import {isNotSaved} from "../../assets/js/offline_bundle.js"
import {SavedKind, answerNetworkFirst, answerSavedFile, savedFileReader, storedOf} from "../../assets/js/saved_files.js"

const TOTAL_BYTES = 1000
const ETAG = "\"3F2A\""
const CONTENT_TYPE = "application/octet-stream"
const ARCHIVE_PATH = "/tiles/route-stops/dt=2026-11-08/route-stops-1.pmtiles"
const CHUNK_PATH = "/routing/2026-11-08/connections-0-abcd.bin"
const UNSAVED_PATH = "/routing/2026-11-09/stops-ef01.bin"
const MANIFEST_PATH = "/api/routing/manifest"
const BUNDLE_MANIFEST_PATH = "/offline-schedules/manifest.json"
const HELD_COUNT_MAX = 2
const BYTE_VALUE_COUNT = 256

const rangeCases = [
  {name: "no Range header", header: null, range: {kind: RangeKind.whole}},
  {name: "a closed range, as pmtiles asks", header: "bytes=0-99", range: {kind: RangeKind.partial, start: 0, end: 99}},
  {name: "a closed range in the middle", header: "bytes=100-199", range: {kind: RangeKind.partial, start: 100, end: 199}},
  {name: "a closed range past the end, read to the end", header: "bytes=900-16383", range: {kind: RangeKind.partial, start: 900, end: 999}},
  {name: "an open-ended range", header: "bytes=990-", range: {kind: RangeKind.partial, start: 990, end: 999}},
  {name: "a suffix range", header: "bytes=-10", range: {kind: RangeKind.partial, start: 990, end: 999}},
  {name: "a suffix range longer than the file", header: "bytes=-5000", range: {kind: RangeKind.partial, start: 0, end: 999}},
  {name: "a range that starts at the end", header: "bytes=1000-1099", range: {kind: RangeKind.unsatisfiable}},
  {name: "an open-ended range past the end", header: "bytes=1000-", range: {kind: RangeKind.unsatisfiable}},
  {name: "a suffix range of no bytes", header: "bytes=-0", range: {kind: RangeKind.unsatisfiable}},
  {name: "several ranges, which are ignored", header: "bytes=0-9,20-29", range: {kind: RangeKind.whole}},
  {name: "a range whose end is before its start, which is ignored", header: "bytes=20-9", range: {kind: RangeKind.whole}},
  {name: "another unit, which is ignored", header: "items=0-9", range: {kind: RangeKind.whole}},
  {name: "a range with no positions, which is ignored", header: "bytes=-", range: {kind: RangeKind.whole}}
]

for (const {name, header, range} of rangeCases) {
  deepStrictEqual(requestedRange({header, total: TOTAL_BYTES}), range, name)
}

const answerCases = [
  {
    name: "a partial answer",
    range: {kind: RangeKind.partial, start: 100, end: 199},
    answer: {
      status: 206,
      sliceStart: 100,
      sliceEnd: 200,
      headers: {"accept-ranges": "bytes", "content-length": "100", "content-range": "bytes 100-199/1000", "content-type": CONTENT_TYPE, etag: ETAG}
    }
  },
  {
    name: "a whole answer",
    range: {kind: RangeKind.whole},
    answer: {status: 200, sliceStart: 0, sliceEnd: 1000, headers: {"accept-ranges": "bytes", "content-length": "1000", "content-type": CONTENT_TYPE, etag: ETAG}}
  },
  {
    name: "an unsatisfiable range",
    range: {kind: RangeKind.unsatisfiable},
    answer: {status: 416, sliceStart: 0, sliceEnd: 0, headers: {"accept-ranges": "bytes", "content-length": "0", "content-range": "bytes */1000"}}
  }
]

for (const {name, range, answer} of answerCases) {
  deepStrictEqual(rangeAnswer({range, total: TOTAL_BYTES, etag: ETAG, contentType: CONTENT_TYPE}), answer, name)
}

const untagged = rangeAnswer({range: {kind: RangeKind.partial, start: 0, end: 9}, total: TOTAL_BYTES, etag: null, contentType: CONTENT_TYPE})
deepStrictEqual(
  untagged.headers,
  {"accept-ranges": "bytes", "content-length": "10", "content-range": "bytes 0-9/1000", "content-type": CONTENT_TYPE},
  "a stored file with no ETag is answered with none"
)

// The stored body counts up byte by byte, so a slice is checked by its first
// byte and its length.
const body = new Uint8Array(TOTAL_BYTES)

for (let index = 0; index < TOTAL_BYTES; index += 1) {
  body[index] = index % BYTE_VALUE_COUNT
}

function storedResponse() {
  const blob = new Blob([body])
  return new Response(blob, {status: 200, headers: {etag: ETAG, "content-type": CONTENT_TYPE}})
}

// A store of the paths in `saved`, which counts its reads.
function memoryStore(saved) {
  const reads = []

  async function readStored(path) {
    reads.push(path)

    const isSaved = saved.includes(path)

    if (isSaved) {
      const response = storedResponse()
      return storedOf(response)
    }

    return storedOf(undefined)
  }

  return {reads, readStored}
}

async function offline() {
  // A fetch rejects with a TypeError on a network failure, which this stands for.
  throw new TypeError("Failed to fetch")
}

function networkAnswering(text) {
  const answered = []

  async function fetchNetwork() {
    answered.push(text)
    return new Response(text, {status: 200})
  }

  return {answered, fetchNetwork}
}

async function bytesOf(response) {
  const buffer = await response.arrayBuffer()
  return new Uint8Array(buffer)
}

async function checkSavedFiles() {
  const store = memoryStore([ARCHIVE_PATH, CHUNK_PATH])
  const reader = savedFileReader({readStored: store.readStored, heldCountMax: HELD_COUNT_MAX})
  const network = networkAnswering("from the network")

  // A range of a saved file is sliced from the stored body, online too.
  const partial = await answerSavedFile({path: ARCHIVE_PATH, rangeHeader: "bytes=100-199", reader, fetchNetwork: network.fetchNetwork})
  const partialBytes = await bytesOf(partial)
  deepStrictEqual(partial.status, 206, "a saved range answers 206")
  deepStrictEqual(partial.headers.get("content-range"), "bytes 100-199/1000", "a saved range's Content-Range")
  deepStrictEqual(partial.headers.get("etag"), ETAG, "a saved range keeps the stored ETag")
  deepStrictEqual([partialBytes.length, partialBytes[0]], [100, 100], "a saved range's bytes")
  deepStrictEqual(network.answered, [], "a saved file is never fetched")

  // The stored body is read once per path while the path is held.
  await answerSavedFile({path: ARCHIVE_PATH, rangeHeader: "bytes=0-9", reader, fetchNetwork: network.fetchNetwork})
  await answerSavedFile({path: ARCHIVE_PATH, rangeHeader: "bytes=-10", reader, fetchNetwork: network.fetchNetwork})
  deepStrictEqual(store.reads, [ARCHIVE_PATH], "a held file is read from the store once")

  // A whole request of a saved file is the stored body.
  const whole = await answerSavedFile({path: CHUNK_PATH, rangeHeader: null, reader, fetchNetwork: offline})
  const wholeBytes = await bytesOf(whole)
  deepStrictEqual([whole.status, wholeBytes.length], [200, TOTAL_BYTES], "a saved file asked for whole")

  const unsatisfiable = await answerSavedFile({path: ARCHIVE_PATH, rangeHeader: "bytes=1000-", reader, fetchNetwork: offline})
  deepStrictEqual([unsatisfiable.status, unsatisfiable.headers.get("content-range")], [416, "bytes */1000"], "an unsatisfiable range of a saved file")

  // A file the bundle lacks comes from the network while there is one.
  const fetched = await answerSavedFile({path: UNSAVED_PATH, rangeHeader: null, reader, fetchNetwork: network.fetchNetwork})
  const fetchedText = await fetched.text()
  deepStrictEqual(fetchedText, "from the network", "an unsaved file online")

  // Offline, a file the bundle lacks is answered as not saved.
  const missing = await answerSavedFile({path: UNSAVED_PATH, rangeHeader: null, reader, fetchNetwork: offline})
  deepStrictEqual([missing.status, isNotSaved(missing)], [503, true], "an unsaved file offline")

  // A miss is looked for in the store on every request.
  const readsBefore = store.reads.length
  await answerSavedFile({path: UNSAVED_PATH, rangeHeader: null, reader, fetchNetwork: offline})
  deepStrictEqual(store.reads.length, readsBefore + 1, "a missing file is looked for again")

  // At most HELD_COUNT_MAX files are held; the least recently used goes.
  const bounded = memoryStore(["/tiles/a.pmtiles", "/tiles/b.pmtiles", "/tiles/c.pmtiles"])
  const boundedReader = savedFileReader({readStored: bounded.readStored, heldCountMax: HELD_COUNT_MAX})

  for (const path of ["/tiles/a.pmtiles", "/tiles/b.pmtiles", "/tiles/a.pmtiles", "/tiles/c.pmtiles", "/tiles/a.pmtiles", "/tiles/b.pmtiles"]) {
    const read = await boundedReader.read(path)
    deepStrictEqual(read.kind, SavedKind.found, "a held file is found: " + path)
  }

  deepStrictEqual(bounded.reads, ["/tiles/a.pmtiles", "/tiles/b.pmtiles", "/tiles/c.pmtiles", "/tiles/b.pmtiles"], "the least recently used file is let go")
}

// A store of the manifest copies at the paths in `saved`, which records the
// copies kept.
function manifestStore(saved) {
  const copies = []

  async function readStored(fallback) {
    const isSaved = saved.includes(fallback.path)

    if (isSaved) {
      const response = new Response(fallback.cache + " copy", {status: 200})
      return storedOf(response)
    }

    return storedOf(undefined)
  }

  async function storeCopy(response) {
    const text = await response.text()
    copies.push(text)
  }

  return {copies, readStored, storeCopy}
}

async function serverError() {
  return new Response("unavailable", {status: 503})
}

async function checkManifest() {
  const fallbacks = [{cache: "offlineSchedules", path: BUNDLE_MANIFEST_PATH}, {cache: "release", path: MANIFEST_PATH}]

  // Online, the manifest is the network's, and a copy is kept.
  const online = manifestStore([BUNDLE_MANIFEST_PATH, MANIFEST_PATH])
  const network = networkAnswering("network manifest")
  const fresh = await answerNetworkFirst({fetchNetwork: network.fetchNetwork, fallbacks, readStored: online.readStored, storeCopy: online.storeCopy})
  const freshText = await fresh.text()
  deepStrictEqual(freshText, "network manifest", "online, the network's manifest")
  deepStrictEqual(online.copies, ["network manifest"], "online, a copy is kept")

  // Offline, the bundle's own manifest wins over the latest copy.
  const both = manifestStore([BUNDLE_MANIFEST_PATH, MANIFEST_PATH])
  const fromBundle = await answerNetworkFirst({fetchNetwork: offline, fallbacks, readStored: both.readStored, storeCopy: both.storeCopy})
  const fromBundleText = await fromBundle.text()
  deepStrictEqual(fromBundleText, "offlineSchedules copy", "offline, the bundle's manifest")

  // Offline with no bundle, the latest copy.
  const releaseOnly = manifestStore([MANIFEST_PATH])
  const fromRelease = await answerNetworkFirst({fetchNetwork: offline, fallbacks, readStored: releaseOnly.readStored, storeCopy: releaseOnly.storeCopy})
  const fromReleaseText = await fromRelease.text()
  deepStrictEqual(fromReleaseText, "release copy", "offline with no bundle, the latest copy")

  // Offline with neither, not saved.
  const none = manifestStore([])
  const notSaved = await answerNetworkFirst({fetchNetwork: offline, fallbacks, readStored: none.readStored, storeCopy: none.storeCopy})
  deepStrictEqual([notSaved.status, isNotSaved(notSaved)], [503, true], "offline with no copy, not saved")

  // A network answer that is not a success is passed on and not kept.
  const failing = manifestStore([BUNDLE_MANIFEST_PATH])
  const passed = await answerNetworkFirst({fetchNetwork: serverError, fallbacks, readStored: failing.readStored, storeCopy: failing.storeCopy})
  deepStrictEqual([passed.status, isNotSaved(passed), failing.copies], [503, false, []], "a server error is passed on")
}

await checkSavedFiles()
await checkManifest()
console.log("saved files: every case holds")
