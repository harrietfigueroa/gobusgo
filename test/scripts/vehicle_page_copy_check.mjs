// Checks how the service worker answers the vehicle page and keeps its bare
// copy, against cases written out by hand: the network's answer while it
// comes, the copy when the network fails, errs on the server's side, or
// takes longer than the wait, the offline screen with no copy, and which
// answers replace the copy. The network, the copy's store, and the wait are
// functions over values held in memory, the wait a promise each case
// settles itself. Run it with `node test/scripts/vehicle_page_copy_check.mjs`;
// it exits non-zero on the first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {storedOf} from "../../assets/js/saved_files.js"
import {VEHICLE_PAGE_COPY_WAIT_MS, answerVehiclePage, refreshVehiclePageCopy} from "../../assets/js/vehicle_page_copy.js"

const COPY_TEXT = "the stored copy"
const NETWORK_TEXT = "the page the server rendered"
const OFFLINE_TEXT = "the offline screen"
const SERVER_ERROR_STATUS = 502
const NOT_FOUND_STATUS = 404
const COPY_WAIT_EXPECTED_MS = 5 * 1000

const NetworkKind = Object.freeze({answers: "answers", fails: "fails", hangs: "hangs"})
const WaitKind = Object.freeze({ends: "ends", runs: "runs"})

function pageResponse({text, status}) {
  return new Response(text, {status, headers: {"content-type": "text/html; charset=utf-8"}})
}

function networkOf({kind, status}) {
  switch (kind) {
    case NetworkKind.answers:
      return () => Promise.resolve(pageResponse({text: NETWORK_TEXT, status}))
    case NetworkKind.fails:
      return () => Promise.reject(new TypeError("Failed to fetch"))
    case NetworkKind.hangs:
      return () => new Promise(neverSettles)
    default:
      throw new Error("a network of unknown kind: " + kind)
  }
}

function neverSettles() {
  // A promise whose executor calls nothing stays pending.
}

function waitOf(kind) {
  if (kind === WaitKind.ends) {
    return () => Promise.resolve()
  }

  return () => new Promise(neverSettles)
}

// A store that holds at most one copy, as the release's cache holds the
// one path, and records the texts written to it.
function copyStore(hasCopy) {
  const written = []
  let held = storedOf(undefined)

  if (hasCopy) {
    held = storedOf(pageResponse({text: COPY_TEXT, status: 200}))
  }

  async function readCopy() {
    return held
  }

  async function storeCopy(response) {
    const text = await response.text()
    written.push(text)
  }

  return {readCopy, storeCopy, written}
}

function offlineAnswer() {
  return pageResponse({text: OFFLINE_TEXT, status: 503})
}

const answerCases = [
  {
    name: "the network answers, a bare address: its page, stored as the copy",
    hasCopy: true, isBare: true, network: {kind: NetworkKind.answers, status: 200}, wait: WaitKind.runs,
    answer: NETWORK_TEXT, written: [NETWORK_TEXT]
  },
  {
    name: "the network answers under a filter: its page, and the copy stays",
    hasCopy: true, isBare: false, network: {kind: NetworkKind.answers, status: 200}, wait: WaitKind.runs,
    answer: NETWORK_TEXT, written: []
  },
  {
    name: "the network fails: the copy at once",
    hasCopy: true, isBare: true, network: {kind: NetworkKind.fails}, wait: WaitKind.runs,
    answer: COPY_TEXT, written: []
  },
  {
    name: "the network takes longer than the wait: the copy",
    hasCopy: true, isBare: true, network: {kind: NetworkKind.hangs}, wait: WaitKind.ends,
    answer: COPY_TEXT, written: []
  },
  {
    name: "the server errs: the copy",
    hasCopy: true, isBare: true, network: {kind: NetworkKind.answers, status: SERVER_ERROR_STATUS}, wait: WaitKind.runs,
    answer: COPY_TEXT, written: []
  },
  {
    name: "the server answers no such page: passed on, and the copy stays",
    hasCopy: true, isBare: true, network: {kind: NetworkKind.answers, status: NOT_FOUND_STATUS}, wait: WaitKind.runs,
    answer: NETWORK_TEXT, written: []
  },
  {
    name: "no copy and the network answers: its page, stored as the copy",
    hasCopy: false, isBare: true, network: {kind: NetworkKind.answers, status: 200}, wait: WaitKind.ends,
    answer: NETWORK_TEXT, written: [NETWORK_TEXT]
  },
  {
    name: "no copy and the network fails: the offline screen",
    hasCopy: false, isBare: true, network: {kind: NetworkKind.fails}, wait: WaitKind.ends,
    answer: OFFLINE_TEXT, written: []
  },
  {
    name: "no copy and the server errs: passed on",
    hasCopy: false, isBare: true, network: {kind: NetworkKind.answers, status: SERVER_ERROR_STATUS}, wait: WaitKind.ends,
    answer: NETWORK_TEXT, written: []
  }
]

deepStrictEqual(VEHICLE_PAGE_COPY_WAIT_MS, COPY_WAIT_EXPECTED_MS, "the copy is answered after five seconds")

for (const testCase of answerCases) {
  const store = copyStore(testCase.hasCopy)
  const response = await answerVehiclePage({
    isBare: testCase.isBare,
    fetchNetwork: networkOf(testCase.network),
    readCopy: store.readCopy,
    storeCopy: store.storeCopy,
    copyWait: waitOf(testCase.wait),
    offlineAnswer
  })
  const text = await response.text()
  deepStrictEqual({answer: text, written: store.written}, {answer: testCase.answer, written: testCase.written}, testCase.name)
}

const refreshCases = [
  {name: "the activation's fetch answers: stored", network: {kind: NetworkKind.answers, status: 200}, written: [NETWORK_TEXT]},
  {name: "the activation's fetch errs: nothing stored", network: {kind: NetworkKind.answers, status: SERVER_ERROR_STATUS}, written: []},
  {name: "the activation's fetch fails: nothing stored", network: {kind: NetworkKind.fails}, written: []}
]

for (const testCase of refreshCases) {
  const store = copyStore(false)
  await refreshVehiclePageCopy({fetchNetwork: networkOf(testCase.network), storeCopy: store.storeCopy})
  deepStrictEqual(store.written, testCase.written, testCase.name)
}

const failedStore = copyStore(true)

async function failingStore() {
  throw new Error("quota exceeded")
}

const answeredDespiteStore = await answerVehiclePage({
  isBare: true,
  fetchNetwork: networkOf({kind: NetworkKind.answers, status: 200}),
  readCopy: failedStore.readCopy,
  storeCopy: failingStore,
  copyWait: waitOf(WaitKind.runs),
  offlineAnswer
})
const answeredText = await answeredDespiteStore.text()
deepStrictEqual(answeredText, NETWORK_TEXT, "a copy that cannot be stored leaves the network's page answered")

console.log("vehicle page copy check passed")
