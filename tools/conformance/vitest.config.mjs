// Runs every conformance case in browser mode, headless, in each of the three
// engines a rider's browser is built on; WebKit is the nearest test of iOS
// Safari. Vite serves the whole repository, so a case imports the modules
// under assets/js/ and reads a fixture outside this package.
// https://vitest.dev/guide/browser/multiple-setups — checked 2026-11-14
// https://vitest.dev/api/browser/commands — checked 2026-11-14

import {fileURLToPath} from "node:url"
import {playwright} from "@vitest/browser-playwright"
import {defineConfig} from "vitest/config"

const REPOSITORY_ROOT = fileURLToPath(new URL("../..", import.meta.url))

export default defineConfig({
  server: {fs: {allow: [REPOSITORY_ROOT]}},
  test: {
    include: ["tests/**/*.test.mjs"],
    browser: {
      enabled: true,
      provider: playwright(),
      headless: true,
      instances: [{browser: "chromium"}, {browser: "firefox"}, {browser: "webkit"}]
    }
  }
})
