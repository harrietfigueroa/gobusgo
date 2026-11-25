// Checks the bound on each file of a save for offline use with timers the
// check fires by hand: a file within its bound, a file past it whose wait
// never ends, a save its own controller aborts, a save already aborted,
// and a file that fails. Run it with `node test/scripts/save_deadline_check.mjs`;
// it exits non-zero on the first case that differs.

import {deepStrictEqual, rejects} from "node:assert/strict"
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
  await rejects(deadline.withinBound(failing), {message: "network"}, "a file that fails: its failure")
  deepStrictEqual(timers.pending.size, 0, "a file that fails: its timer cleared")
  deepStrictEqual(controller.signal.aborted, false, "a file that fails: the save is not aborted")
}

console.log("save deadline check passed")
