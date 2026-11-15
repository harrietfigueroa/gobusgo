// Runs the parity harness, by hand only: every implementation of the core
// answers the same journey queries over the routing snapshot a published
// site serves, and the answers must agree. The files come through the test
// server's `fileFromOrigin` command, from the site GOBUSGO_FILE_ORIGIN names.
// https://vitest.dev/api/browser/commands — checked 2026-11-14

import {fileURLToPath} from "node:url"
import {playwright} from "@vitest/browser-playwright"
import {defineConfig} from "vitest/config"
import {fileFromOrigin, siteOrigin} from "./origin_files.mjs"

const REPOSITORY_ROOT = fileURLToPath(new URL("../..", import.meta.url))
// A query over a date not yet fetched waits on several megabytes from the site.
const QUERY_TIMEOUT_MS = 120_000

// The run refuses to start without a site to fetch from.
siteOrigin()

export default defineConfig({
  server: {fs: {allow: [REPOSITORY_ROOT]}},
  test: {
    include: ["parity/**/*.parity.mjs"],
    testTimeout: QUERY_TIMEOUT_MS,
    browser: {
      enabled: true,
      provider: playwright(),
      headless: true,
      instances: [{browser: "chromium"}, {browser: "firefox"}, {browser: "webkit"}],
      commands: {fileFromOrigin}
    }
  }
})
