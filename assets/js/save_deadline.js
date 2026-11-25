// The bound on each file of a save for offline use. Everything here takes
// its controller and timers as arguments and touches no store, network, or
// DOM, so a check runs it with timers it fires by hand.
//
// A file's fetch and store run within the bound; past it the save's
// controller aborts with a TimeoutError, which stops every fetch the save
// passes its signal to. A store does not read the signal, and a
// `Cache.put` can stay pending, so the file's wait also ends when the
// signal aborts, and the save ends with it.

/** The longest one file's fetch and store take before its save is aborted, 5 minutes. */
export const FILE_SAVE_MS_MAX = 5 * 60 * 1000

const TIMEOUT_MESSAGE = "A file of the offline save took longer than its bound"

/**
 * The deadline of one save: `signal`, the save's abort signal, and
 * `withinBound(operation)`, which runs `operation`, a function returning a
 * promise, and rejects with the signal's reason once the signal aborts,
 * whether the bound of `fileMsMax` or the save's own controller aborted it.
 * `timers` holds `setTimeout` and `clearTimeout`.
 */
export function saveDeadlineOf({controller, timers, fileMsMax}) {
  const {signal} = controller

  function abortForTimeout() {
    const reason = new DOMException(TIMEOUT_MESSAGE, "TimeoutError")
    controller.abort(reason)
  }

  async function withinBound(operation) {
    signal.throwIfAborted()
    let onAbort = null

    function abortedExecutor(_resolve, reject) {
      onAbort = () => { reject(signal.reason) }
      signal.addEventListener("abort", onAbort, {once: true})
    }

    const aborted = new Promise(abortedExecutor)
    const timer = timers.setTimeout(abortForTimeout, fileMsMax)
    const pending = operation()
    let isRaceSettled = false

    // An operation the abort outran settles after the save has moved on: a
    // failure of the abort's making is expected, and anything else is
    // logged. A failure that settles the race is the caller's.
    function lateFailureCallback(error) {
      if (isRaceSettled) {
        warnLateFailure(error)
      }
    }

    pending.catch(lateFailureCallback)

    try {
      return await Promise.race([pending, aborted])
    } finally {
      isRaceSettled = true
      timers.clearTimeout(timer)
      signal.removeEventListener("abort", onAbort)
    }
  }

  return Object.freeze({signal, withinBound})
}

function warnLateFailure(error) {
  const isAbort = error.name === "AbortError" || error.name === "TimeoutError"

  if (!isAbort) {
    console.warn("Offline save's file failed after its save ended", error)
  }
}
