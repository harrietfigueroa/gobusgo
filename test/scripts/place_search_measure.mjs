// Measures the place search in headless Chrome over the real places: the
// time to build the index, the median and the slowest of the 30 queries'
// medians, typing "pike place market" one letter at a time, and the heap
// plus the array buffers' backing stores after a forced collection. Run it
// at each CPU throttle rate to stand in for a phone:
// `node test/scripts/place_search_measure.mjs --chrome <executable> --records <records json> [--throttle 4]`.
// It serves the module from `assets/js/` and the table cut from the records
// on localhost, reads nothing else, and prints one JSON object.

import {spawn} from "node:child_process"
import {readFileSync, mkdtempSync, rmSync} from "node:fs"
import {once} from "node:events"
import {createServer} from "node:http"
import {tmpdir} from "node:os"
import {join, normalize} from "node:path"
import {setTimeout as sleep} from "node:timers/promises"
import {parseArgs} from "node:util"
import {assertCondition} from "../../assets/js/assert.js"
import {jsonColumnsOfTable, tableOfRecords} from "./place_records.mjs"

const HALF = 2
const REPORT_INDENT = 2
const REPEAT_COUNT = 11
const RESULT_COUNT = 8
const TYPING_QUERY = "pike place market"
const READY_ATTEMPTS_MAX = 100
const READY_WAIT_MS = 100
const BYTES_PER_MEBIBYTE = 1048576
const REPOSITORY_ROOT = new URL("../../", import.meta.url).pathname
const INTENDED_PATH = join(REPOSITORY_ROOT, "test/fixtures/places/queries/intended_places.json")

const HARNESS_HTML = `<!doctype html><html lang="en"><head><meta charset="utf-8"><title>Place search harness</title></head><body><main><h1>Place search harness</h1><script type="module" src="/harness.js"></script></main></body></html>`

const HARNESS_JS = `
import {buildPlaceIndex, searchPlaces} from "/assets/js/place_search.js"

let index = null

async function load() {
  const response = await fetch("/table.json", {cache: "no-store"})
  const columns = await response.json()
  const started = performance.now()
  const table = {
    placeCount: columns.placeCount,
    names: columns.names,
    aliasStarts: Uint32Array.from(columns.aliasStarts),
    aliasNames: columns.aliasNames,
    latitudeMicrodegrees: Int32Array.from(columns.latitudeMicrodegrees),
    longitudeMicrodegrees: Int32Array.from(columns.longitudeMicrodegrees),
    categories: Uint8Array.from(columns.categories),
    prominences: Uint8Array.from(columns.prominences),
    areas: Uint8Array.from(columns.areas),
    categoryNames: columns.categoryNames
  }
  const decoded = performance.now()
  index = buildPlaceIndex(table)
  const built = performance.now()
  return {places: index.placeCount, words: index.words.length, postings: index.postings.length, decodeMs: decoded - started, buildMs: built - decoded}
}

function run({queries, center, repeats, resultCountMax}) {
  const rows = []
  for (const query of queries) {
    const times = []
    for (let repeat = 0; repeat < repeats; repeat++) {
      const started = performance.now()
      searchPlaces({index, query, center, resultCountMax})
      times.push(performance.now() - started)
    }
    times.sort((left, right) => left - right)
    rows.push({query, medianMs: times[Math.floor(times.length / 2)], maxMs: times[times.length - 1]})
  }
  return rows
}

function typing({query, center, resultCountMax}) {
  const times = []
  for (let length = 1; length <= query.length; length++) {
    const started = performance.now()
    searchPlaces({index, query: query.slice(0, length), center, resultCountMax})
    times.push(performance.now() - started)
  }
  return times
}

window.placeHarness = {load, run, typing}
window.placeHarnessReady = true
`

function startServer(tableJson) {
  const server = createServer((request, response) => {
    const path = new URL(request.url, "http://localhost").pathname

    if (path === "/harness.html") {
      response.writeHead(200, {"content-type": "text/html"})
      response.end(HARNESS_HTML)
      return
    }

    if (path === "/harness.js") {
      response.writeHead(200, {"content-type": "text/javascript"})
      response.end(HARNESS_JS)
      return
    }

    if (path === "/table.json") {
      response.writeHead(200, {"content-type": "application/json"})
      response.end(tableJson)
      return
    }

    const file = normalize(join(REPOSITORY_ROOT, path))
    const isModule = file.startsWith(join(REPOSITORY_ROOT, "assets/js/")) && file.endsWith(".js")

    if (!isModule) {
      response.writeHead(404)
      response.end()
      return
    }

    response.writeHead(200, {"content-type": "text/javascript"})
    response.end(readFileSync(file))
  })

  return new Promise((resolve) => server.listen(0, "127.0.0.1", () => resolve(server)))
}

async function startChrome({executable, profile}) {
  const flags = ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--enable-precise-memory-info", "--no-first-run", "--no-default-browser-check", "about:blank"]
  const browser = spawn(executable, flags, {stdio: ["ignore", "ignore", "pipe"]})

  const address = await new Promise((resolve) => {
    browser.stderr.on("data", (chunk) => {
      const match = /DevTools listening on (ws:\/\/\S+)/.exec(chunk.toString())

      if (match !== null) {
        resolve(match[1])
      }
    })
  })

  return {browser, address}
}

function connect(address) {
  const socket = new WebSocket(address)
  const pending = new Map()
  let nextId = 1

  socket.addEventListener("message", (event) => {
    const message = JSON.parse(event.data)
    const resolve = pending.get(message.id)

    if (resolve !== undefined) {
      pending.delete(message.id)
      resolve(message)
    }
  })

  function send({method, params, sessionId}) {
    const id = nextId
    nextId++
    socket.send(JSON.stringify({id, method, params, sessionId}))
    return new Promise((resolve) => pending.set(id, resolve))
  }

  const opened = new Promise((resolve) => socket.addEventListener("open", resolve))
  return {socket, send, opened}
}

function median(numbers) {
  const sorted = Array.from(numbers).sort((left, right) => left - right)
  return sorted[Math.floor(sorted.length / HALF)]
}

function largest(numbers) {
  let best = 0

  for (const number of numbers) {
    if (number > best) {
      best = number
    }
  }

  return best
}

function queryOfEntry(entry) {
  return entry.query
}

function medianOfRow(row) {
  return row.medianMs
}

const {values} = parseArgs({options: {chrome: {type: "string"}, records: {type: "string"}, throttle: {type: "string", default: "1"}}, strict: true})
assertCondition(values.chrome !== undefined, "place search measure: --chrome is required")
assertCondition(values.records !== undefined, "place search measure: --records is required")
const throttle = Number(values.throttle)
assertCondition(Number.isSafeInteger(throttle), `place search measure: the throttle is not an integer: ${values.throttle}`)
assertCondition(throttle >= 1, `place search measure: the throttle is under 1: ${values.throttle}`)

const records = JSON.parse(readFileSync(values.records, "utf8"))
const intended = JSON.parse(readFileSync(INTENDED_PATH, "utf8"))
const queries = Array.from(intended.queries, queryOfEntry)
const columns = jsonColumnsOfTable(tableOfRecords(records))
const tableJson = JSON.stringify(columns)
const server = await startServer(tableJson)
const profileParent = tmpdir()
const profile = mkdtempSync(join(profileParent, "place-search-chrome-"))
const {browser, address} = await startChrome({executable: values.chrome, profile})
const {socket, send, opened} = connect(address)
await opened

const created = await send({method: "Target.createTarget", params: {url: "about:blank"}})
const attached = await send({method: "Target.attachToTarget", params: {targetId: created.result.targetId, flatten: true}})
const sessionId = attached.result.sessionId

function page(method, params) {
  return send({method, params, sessionId})
}

async function evaluate(expression) {
  const reply = await page("Runtime.evaluate", {expression, awaitPromise: true, returnByValue: true})
  assertCondition(reply.result.exceptionDetails === undefined, `place search measure: ${JSON.stringify(reply.result.exceptionDetails)}`)
  return reply.result.result.value
}

async function heapBytes() {
  await page("HeapProfiler.collectGarbage", {})
  await page("HeapProfiler.collectGarbage", {})
  const reply = await page("Runtime.getHeapUsage", {})
  return reply.result.usedSize + reply.result.backingStorageSize
}

const {port} = server.address()
await page("Runtime.enable", {})
await page("HeapProfiler.enable", {})
await page("Page.navigate", {url: `http://127.0.0.1:${port}/harness.html`})

for (let attempt = 0; attempt < READY_ATTEMPTS_MAX; attempt++) {
  const isReady = await evaluate("window.placeHarnessReady === true")

  if (isReady) {
    break
  }

  await sleep(READY_WAIT_MS)
}

if (throttle > 1) {
  await page("Emulation.setCPUThrottlingRate", {rate: throttle})
}

const heapBefore = await heapBytes()
const load = await evaluate("window.placeHarness.load()")
const heapAfter = await heapBytes()
const runOptions = JSON.stringify({queries, center: intended.center, repeats: REPEAT_COUNT, resultCountMax: RESULT_COUNT})
const rows = await evaluate(`window.placeHarness.run(${runOptions})`)
const typingOptions = JSON.stringify({query: TYPING_QUERY, center: intended.center, resultCountMax: RESULT_COUNT})
const typing = await evaluate(`window.placeHarness.typing(${typingOptions})`)

const medians = Array.from(rows, medianOfRow)
const report = {
  throttle,
  places: load.places,
  words: load.words,
  postings: load.postings,
  decodeMs: load.decodeMs,
  buildMs: load.buildMs,
  heapPlusBuffersMegabytes: (heapAfter - heapBefore) / BYTES_PER_MEBIBYTE,
  queryMedianOfMediansMs: median(medians),
  querySlowestMedianMs: largest(medians),
  typingSlowestMs: largest(typing),
  typingMs: typing
}

console.log(JSON.stringify(report, null, REPORT_INDENT))
socket.close()
browser.kill()
await once(browser, "exit")
server.close()
rmSync(profile, {recursive: true, force: true})
