// Checks the bound on each file of a save for offline use with timers the
// check fires by hand: a file within its bound, a file past it whose wait
// never ends, a save its own controller aborts, a save already aborted,
// a file that fails, and a file the bound outran failing later, an
// assertion failure among them. Run it with `node test/scripts/save_deadline_check.mjs`;
// it exits non-zero on the first case that differs.

import {deepStrictEqual, rejects} from "node:assert/strict"
import {setImmediate as setImmediatePromise} from "node:timers/promises"
import {AssertionError} from "../../assets/js/core/assert.js"
import {FILE_SAVE_MS_MAX, saveDeadlineOf} from "../../assets/js/save_deadline.js"

const FIVE_MINUTES_MS = 5 * 60 * 1000
const FILE_MS_MAX = 1000

// Timers that record each timeout and fire one only when the check asks.
function handTimers() {
  const pending = new Map()
  let nextId = 1

  return {
    pending,
    setTimeout(callback, ms) {
      const id = nextId
      nextId += 1
      pending.set(id, {callback, ms})
      return id
    },
    clearTimeout(id) {
      pending.delete(id)
    },
    fireAll() {
      for (const [id, {callback}] of pending) {
        pending.delete(id)
        callback()
      }
    }
  }
}

function neverSettles() {
  return new Promise(ignoreExecutor)
}

function ignoreExecutor() {
  // Neither callback is called, so the promise stays pending, as a store
  // that never settles does.
}

async function storedValue() {
  return "stored"
}

// An operation whose promise the check rejects when it chooses.
function settleableLater() {
  let rejectLater = null

  function executor(_resolve, reject) {
    rejectLater = reject
  }

  const promise = new Promise(executor)

  function operation() {
    return promise
  }

  function reject(failure) {
    rejectLater(failure)
  }

  return {operation, reject}
}

// The descriptions `console.warn` receives while `run` runs and a turn of
// the event loop after it, so a late failure's handler has run.
async function warningsDuring(run) {
  const warn = console.warn
  const warnings = []

  function recordWarning(description) {
    warnings.push(description)
  }

  console.warn = recordWarning

  try {
    await run()
    await setImmediatePromise()
  } finally {
    console.warn = warn
  }

  return warnings
}

// A file whose fetch fails, as a rejected promise rather than a throw.
function failing() {
  return Promise.reject(new Error("network"))
}

deepStrictEqual(FILE_SAVE_MS_MAX, FIVE_MINUTES_MS, "the bound is five minutes")

{
  const timers = handTimers()
  const controller = new AbortController()
  const deadline = saveDeadlineOf({controller, timers, fileMsMax: FILE_MS_MAX})
  const value = await deadline.withinBound(storedValue)
  deepStrictEqual(value, "stored", "a file within its bound: its value")
  deepStrictEqual(timers.pending.size, 0, "a file within its bound: its timer cleared")
  deepStrictEqual(controller.signal.aborted, false, "a file within its bound: the save goes on")
}

{
  const timers = handTimers()
  const controller = new AbortController()
  const deadline = saveDeadlineOf({controller, timers, fileMsMax: FILE_MS_MAX})
  const waiting = deadline.withinBound(neverSettles)
  const [timer] = timers.pending.values()
  deepStrictEqual(timer.ms, FILE_MS_MAX, "a file past its bound: the timer is the bound")
  timers.fireAll()
  await rejects(waiting, {name: "TimeoutError"}, "a file past its bound: its wait ends with a TimeoutError")
  deepStrictEqual(controller.signal.aborted, true, "a file past its bound: the save is aborted")
  deepStrictEqual(controller.signal.reason.name, "TimeoutError", "a file past its bound: the abort's reason")
}

{
  const timers = handTimers()
  const controller = new AbortController()
  const deadline = saveDeadlineOf({controller, timers, fileMsMax: FILE_MS_MAX})
  const waiting = deadline.withinBound(neverSettles)
  controller.abort()
  await rejects(waiting, {name: "AbortError"}, "a save its controller aborts: the file's wait ends")
  deepStrictEqual(timers.pending.size, 0, "a save its controller aborts: the timer cleared")
}

{
  const timers = handTimers()
  const controller = new AbortController()
  controller.abort()
  const deadline = saveDeadlineOf({controller, timers, fileMsMax: FILE_MS_MAX})
  let isCalled = false

  async function operation() {
    isCalled = true
  }

  await rejects(deadline.withinBound(operation), {name: "AbortError"}, "a save already aborted: refused")
  deepStrictEqual(isCalled, false, "a save already aborted: no file is fetched")
}

{
  const timers = handTimers()
  const controller = new AbortController()
  const deadline = saveDeadlineOf({controller, timers, fileMsMax: FILE_MS_MAX})
  const warnings = await warningsDuring(() => rejects(deadline.withinBound(failing), {message: "network"}, "a file that fails: its failure"))
  deepStrictEqual(timers.pending.size, 0, "a file that fails: its timer cleared")
  deepStrictEqual(controller.signal.aborted, false, "a file that fails: the save is not aborted")
  deepStrictEqual(warnings, [], "a file that fails: its failure is the caller's, not warned")
}

{
  const timers = handTimers()
  const controller = new AbortController()
  const deadline = saveDeadlineOf({controller, timers, fileMsMax: FILE_MS_MAX})
  const failure = new Error("thrown at once")

  function throwing() {
    throw failure
  }

  await rejects(deadline.withinBound(throwing), {message: "thrown at once"}, "a file that throws at once: its failure")
  deepStrictEqual(timers.pending.size, 0, "a file that throws at once: its timer cleared")
}

// A file the bound outran fails later: a failure of the abort's making is
// expected, and any other is warned.
const lateFailureCases = [
  {name: "a failure of its own", failure: new Error("disk"), warningCount: 1},
  {name: "an abort", failure: new DOMException("stopped", "AbortError"), warningCount: 0},
  {name: "a timeout", failure: new DOMException("late", "TimeoutError"), warningCount: 0}
]

for (const lateCase of lateFailureCases) {
  const timers = handTimers()
  const controller = new AbortController()
  const deadline = saveDeadlineOf({controller, timers, fileMsMax: FILE_MS_MAX})
  const late = settleableLater()

  async function lateRun() {
    const waiting = deadline.withinBound(late.operation)
    timers.fireAll()
    await rejects(waiting, {name: "TimeoutError"}, `a late failure, ${lateCase.name}: the bound ends the wait`)
    late.reject(lateCase.failure)
  }

  const warnings = await warningsDuring(lateRun)
  deepStrictEqual(warnings.length, lateCase.warningCount, `a late failure, ${lateCase.name}: warnings`)
}

// A programmer error the bound outran is never a warning: it rejects
// unhandled, which ends the process outside this check.
{
  const timers = handTimers()
  const controller = new AbortController()
  const deadline = saveDeadlineOf({controller, timers, fileMsMax: FILE_MS_MAX})
  const late = settleableLater()
  const failure = new AssertionError("a broken invariant")
  const unhandled = []

  function recordUnhandled(reason) {
    unhandled.push(reason)
  }

  async function lateRun() {
    const waiting = deadline.withinBound(late.operation)
    timers.fireAll()
    await rejects(waiting, {name: "TimeoutError"}, "a late assertion failure: the bound ends the wait")
    late.reject(failure)
  }

  process.on("unhandledRejection", recordUnhandled)

  try {
    const warnings = await warningsDuring(lateRun)
    await setImmediatePromise()
    deepStrictEqual(warnings, [], "a late assertion failure: not warned")
  } finally {
    process.off("unhandledRejection", recordUnhandled)
  }

  deepStrictEqual(unhandled, [failure], "a late assertion failure: rethrown")
}

console.log("save deadline check passed")
