// Checks the service worker's answer to a page's question of its release, by
// running the worker against a stand-in for its global scope, handing its
// message handler a `release` question with a port, and reading the answer
// on the port's other end. It runs the worker's source with a release of its
// own, and the worker `mix assets.build` wrote to `priv/static/sw.js`, whose
// answer must name the release of the release file the build wrote beside
// it, in the format the page reads. Run it after `mix assets.build` with
// `node test/scripts/service_worker_release_check.mjs`; it prints each case
// and exits non-zero when any case differs.

import {deepStrictEqual} from "node:assert/strict"
import {readFile} from "node:fs/promises"
import {runInThisContext} from "node:vm"
import {PageReleaseKind, ReleaseAnswerKind, pageReleaseOf, releaseAnswerOf} from "../../assets/js/release_offer.js"
import {MessageKind} from "../../assets/js/service_worker_strategy.js"

// Each field of the source worker's build holds a value of its own, so an
// answer that names another field than the release differs.
const SOURCE_RELEASE = "0123456789abcdef"
const SOURCE_BASEMAP_ASSETS_ID = "fedcba9876543210"
const SOURCE_PRECACHE_PATH = "/assets/js/app.js"
// How long a case waits for the worker's answer before it reads none.
const ANSWER_WAIT_MS = 1000
const NO_ANSWER = "no answer"
const BUILT_WORKER_URL = new URL("../../priv/static/sw.js", import.meta.url)
const RELEASE_FILE_URL = new URL("../../priv/static/sw_release.json", import.meta.url)

// The worker's global scope as its listeners and its activate message reach
// it; `skipWaitingCount` counts the takeovers it asks for. A message makes
// it the global `self` again, since the worker reads `self` when a message
// arrives as well as when it loads.
function standInScope() {
  const listeners = new Map()
  const scope = {
    skipWaitingCount: 0,
    addEventListener(type, listener) {
      listeners.set(type, listener)
    },
    skipWaiting() {
      scope.skipWaitingCount += 1
      return Promise.resolve()
    },
    message(data, ports) {
      const listener = listeners.get("message")
      globalThis.self = scope
      listener({data, ports})
    }
  }
  return scope
}

let sourceLoadCount = 0

// A source worker of its own: the query gives each load a module instance
// of its own, which registers its listeners on this load's scope.
async function sourceWorker() {
  const scope = standInScope()
  sourceLoadCount += 1
  globalThis.self = scope
  globalThis.SERVICE_WORKER_BUILD = {release: SOURCE_RELEASE, precachePaths: [SOURCE_PRECACHE_PATH], basemapAssetsId: SOURCE_BASEMAP_ASSETS_ID}
  await import(`../../assets/js/service_worker.js?load=${sourceLoadCount}`)
  return scope
}

async function builtWorker() {
  const source = await readFile(BUILT_WORKER_URL, "utf8")
  const scope = standInScope()
  globalThis.self = scope
  runInThisContext(source, {filename: BUILT_WORKER_URL.pathname})
  return scope
}

// The answer `scope` gives on the port a release question hands it.
async function answerOf(scope) {
  const channel = new MessageChannel()
  let timer = null

  function answeringExecutor(resolve) {
    channel.port1.onmessage = resolve
    timer = setTimeout(resolve, ANSWER_WAIT_MS, {data: NO_ANSWER})
  }

  const answering = new Promise(answeringExecutor)
  scope.message({kind: MessageKind.release}, [channel.port2])
  const event = await answering
  clearTimeout(timer)
  channel.port1.close()
  channel.port2.close()
  return event.data
}

async function releaseFileRelease() {
  const content = await readFile(RELEASE_FILE_URL, "utf8")
  const file = JSON.parse(content)
  return file.release
}

const cases = [
  {
    name: "the worker answers a release question on the port it hands with its release",
    async check() {
      const source = await sourceWorker()
      const answer = await answerOf(source)
      deepStrictEqual(answer, {kind: MessageKind.release, release: SOURCE_RELEASE})
    }
  },
  {
    name: "the page reads the worker's answer as the worker's release",
    async check() {
      const source = await sourceWorker()
      const answer = await answerOf(source)
      const read = releaseAnswerOf(answer)
      deepStrictEqual(read, {kind: ReleaseAnswerKind.release, release: SOURCE_RELEASE})
    }
  },
  {
    name: "the worker asks to take over on an activate message",
    async check() {
      const source = await sourceWorker()
      source.message({kind: MessageKind.activate}, [])
      deepStrictEqual(source.skipWaitingCount, 1)
    }
  },
  {
    name: "the built worker answers with the release the build's release file names",
    async check() {
      const built = await builtWorker()
      const answer = await answerOf(built)
      const fileRelease = await releaseFileRelease()
      deepStrictEqual(answer, {kind: MessageKind.release, release: fileRelease})
    }
  },
  {
    name: "the page reads the release the build's release file names as a release",
    async check() {
      const fileRelease = await releaseFileRelease()
      const pageRelease = pageReleaseOf(fileRelease)
      deepStrictEqual(pageRelease, {kind: PageReleaseKind.known, release: fileRelease})
    }
  }
]

let failureCount = 0

for (const testCase of cases) {
  try {
    await testCase.check()
    console.log(`pass: ${testCase.name}`)
  } catch (error) {
    failureCount = failureCount + 1
    console.log(`FAIL: ${testCase.name}: ${error.message}`)
  }
}

console.log(`service worker release: ${cases.length - failureCount} of ${cases.length} cases pass`)
process.exitCode = failureCount
