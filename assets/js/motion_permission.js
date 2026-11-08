// The browser's motion permission, which Safari on iOS asks for before it
// hands the page orientation events. The request needs the transient
// activation of a click and shows the browser's own prompt; a denial is
// stored, so the page never asks again.
// https://developer.mozilla.org/en-US/docs/Web/API/DeviceOrientationEvent/requestPermission_static — checked 2026-11-08

import {storedSettings} from "./stored_settings"

const DENIED = "denied"

/** Whether this browser asks for the motion permission before it hands out orientation events. */
export function canRequestMotionPermission() {
  const hasEvent = typeof window.DeviceOrientationEvent === "function"
  const canRequest = hasEvent && typeof window.DeviceOrientationEvent.requestPermission === "function"
  return canRequest
}

/** Whether the rider denied the motion permission once already. */
export function isMotionPermissionDenied() {
  return storedSettings.readMotionPermissionDenied()
}

/**
 * Asks for the motion permission, in the click that calls it, and stores a
 * denial. A browser that does not ask, and a denial already stored, ask
 * nothing.
 */
export async function requestMotionPermission() {
  const isAskable = canRequestMotionPermission() && !isMotionPermissionDenied()

  if (!isAskable) {
    return
  }

  // A request outside a click rejects with NotAllowedError and leaves the
  // permission unanswered, so nothing is stored for it.
  try {
    const answer = await window.DeviceOrientationEvent.requestPermission()

    if (answer === DENIED) {
      storedSettings.writeMotionPermissionDenied()
    }
  } catch (error) {
    console.warn("Motion permission not requested", error)
  }
}
