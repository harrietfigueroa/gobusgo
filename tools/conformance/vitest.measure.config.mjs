// Runs the measurements, by hand only and never in CI: each times the
// implementations of the core over the files a published site serves, in
// Chromium, Firefox, and WebKit, and prints what it measured. The files come
// through the test server's `fileFromOrigin` command, from the site
// GOBUSGO_FILE_ORIGIN names.
// https://vitest.dev/api/browser/commands — checked 2026-11-14

import {fileURLToPath} from "node:url"
import {playwright} from "@vitest/browser-playwright"
import {defineConfig} from "vitest/config"
import {fileFromOrigin, siteOrigin} from "./origin_files.mjs"

const REPOSITORY_ROOT = fileURLToPath(new URL("../..", import.meta.url))
// The first run of a date waits on several megabytes from the site.
const MEASUREMENT_TIMEOUT_MS = 300_000

// The run refuses to start without a site to fetch from.
siteOrigin()

// Prints a measurement's line from the test server, whose output the run
// shows whatever its reporter does with a browser's console.
function reportMeasurement(_context, line) {
  process.stdout.write(`${line}\n`)
}

export default defineConfig({
  server: {fs: {allow: [REPOSITORY_ROOT]}},
  test: {
    include: ["measurements/**/*.measure.mjs"],
    testTimeout: MEASUREMENT_TIMEOUT_MS,
    // One browser at a time, so no measurement shares the machine with another.
    fileParallelism: false,
    browser: {
      enabled: true,
      provider: playwright(),
      headless: true,
      instances: [{browser: "chromium"}, {browser: "firefox"}, {browser: "webkit"}],
      commands: {fileFromOrigin, reportMeasurement}
    }
  }
})
