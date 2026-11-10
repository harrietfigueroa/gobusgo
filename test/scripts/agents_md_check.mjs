// Checks the agent guidance files against the tree: every repository path
// one of them names in a code span exists, every guidance file below the
// root is named in the root file's area map, and every area file the map
// names exists. It reads the tracked files from git, so a file a build
// writes and git ignores counts as absent unless it is listed in
// GENERATED_PATHS, first checks the rules against Markdown written out by
// hand, then checks every guidance file. Run it with
// `node test/scripts/agents_md_check.mjs`; it exits non-zero and names the
// file and line of each failure.

import {deepStrictEqual} from "node:assert/strict"
import {execFileSync} from "node:child_process"
import {readFileSync} from "node:fs"
import {posix} from "node:path"

const REPOSITORY_ROOT = new URL("../../", import.meta.url)
const AGENTS_FILE_NAME = "AGENTS.md"
const AREA_MAP_HEADING = "## Area map"
const GIT_OUTPUT_BYTES_MAX = 16 * 1024 * 1024

// Paths the guidance files name that a build or a run writes and git
// ignores, so a checkout holds none of them. A named path inside one of
// these is accepted too.
const GENERATED_PATHS = Object.freeze({
  "assets/vendor/": "mix gobusgo.vendor.fetch downloads the vendored npm packages here",
  "priv/vendor/": "mix gobusgo.vendor.fetch downloads the vendored archives here",
  "priv/static/assets/": "mix assets.build writes the built stylesheet, script, and MapLibre's files here",
  "priv/static/sw.js": "mix gobusgo.assets.service_worker bundles the service worker here",
  "tools/lint/rendered/": "the accessibility test writes the rendered pages here for html-eslint"
})

// Code spans that the path rule reads as paths of this repository and that
// name something else.
const NOT_REPOSITORY_PATHS = Object.freeze({
  ".git/index.lock": "the lock file of a checkout, which no checkout tracks",
  "index.lock": "the lock file of a checkout, which no checkout tracks",
  "application-release.yml": "a workflow of the infrastructure repository",
  "application-deploy.yml": "a workflow of the infrastructure repository",
  "gbfs.json": "a file a GBFS feed publishes",
  "gbfs_versions.json": "a file a GBFS feed publishes",
  "manifest.json": "the manifest of the basemap directory under GOBUSGO_DATA_DIR, outside the repository"
})

const SpanKind = Object.freeze({
  path: "path",
  otherText: "other-text"
})

const FailureKind = Object.freeze({
  missingPath: "missing-path",
  unmappedAreaFile: "unmapped-area-file",
  missingAreaFile: "missing-area-file"
})

const CODE_SPAN_PATTERN = /`([^`\n]+)`/g
const FENCE_PATTERN = /^\s*(```|~~~)/
const WHITESPACE_PATTERN = /\s/
// A placeholder such as `<date>` or a glob's `*` starts the part of a span
// that names no one path, so only what comes before it is checked.
const PLACEHOLDER_PATTERN = /[<*]/
const MAP_ENTRY_PATTERN = /^- `([^`]+)`/

function* codeSpans(markdown) {
  const lines = markdown.split("\n")
  let isInFence = false

  for (const [index, line] of lines.entries()) {
    if (FENCE_PATTERN.test(line)) {
      isInFence = !isInFence
    } else if (!isInFence) {
      for (const match of line.matchAll(CODE_SPAN_PATTERN)) {
        yield {text: match[1], line: index + 1}
      }
    }
  }
}

function placeholderIndex(text) {
  const match = PLACEHOLDER_PATTERN.exec(text)

  if (match === null) {
    return text.length
  }

  return match.index
}

// The part of a span to look up: the whole span, or for a span with a
// placeholder the directory that holds the placeholder.
function fixedPart(text) {
  const index = placeholderIndex(text)

  if (index === text.length) {
    return text
  }

  const prefix = text.slice(0, index)
  const slashIndex = prefix.lastIndexOf("/")
  return prefix.slice(0, slashIndex + 1)
}

/**
 * What a code span names: `{kind: SpanKind.path, path}` with the repository
 * path as written, or `{kind: SpanKind.otherText}`. A span names a path when
 * it holds no whitespace before any placeholder, is no URL and no site route
 * (which starts with `/`), and either starts with a top-level directory
 * followed by `/` or ends in a file name whose extension a tracked file has.
 */
export function namedPath({text, topDirectories, extensions}) {
  const fixed = fixedPart(text)
  const hasWhitespace = WHITESPACE_PATTERN.test(fixed)
  const isUrl = fixed.includes("://")
  const isRoute = fixed.startsWith("/")
  const isEmpty = fixed.length === 0
  const isProseOrUrl = hasWhitespace || isUrl
  const isRouteOrEmpty = isRoute || isEmpty
  const isOtherText = isProseOrUrl || isRouteOrEmpty

  if (isOtherText) {
    return {kind: SpanKind.otherText}
  }

  const slashIndex = fixed.indexOf("/")
  const firstSegment = fixed.slice(0, slashIndex)
  const hasSlash = slashIndex > 0
  const startsWithDirectory = hasSlash && topDirectories.has(firstSegment)

  if (startsWithDirectory) {
    return {kind: SpanKind.path, path: fixed}
  }

  const extension = posix.extname(fixed)
  const hasExtension = extension.length > 0
  const hasTrackedExtension = hasExtension && extensions.has(extension)

  if (hasTrackedExtension) {
    return {kind: SpanKind.path, path: fixed}
  }

  return {kind: SpanKind.otherText}
}

function isGenerated(path) {
  for (const generated of Object.keys(GENERATED_PATHS)) {
    const isDirectory = generated.endsWith("/")
    const isInside = isDirectory && path.startsWith(generated)
    const isSame = path === generated
    const isSameDirectory = `${path}/` === generated
    const isNamed = isSame || isSameDirectory
    const isCovered = isNamed || isInside

    if (isCovered) {
      return true
    }
  }

  return false
}

// A path names a directory when it ends in `/`, and a file or a directory
// otherwise. A path that is not found from the root is looked up from the
// directory of the guidance file that names it, and a bare file name, which
// an area file writes in a list under the directory that holds it, is found
// when any tracked file has that name.
function pathExists({path, directory, entries, fileNames}) {
  const isBareName = !path.includes("/")
  const isTrackedName = isBareName && fileNames.has(path)

  if (isTrackedName) {
    return true
  }

  const fromRoot = posix.normalize(path)
  const fromDirectory = posix.normalize(posix.join(directory, path))

  for (const candidate of [fromRoot, fromDirectory]) {
    const isCandidateGenerated = isGenerated(candidate)
    const isFound = entries.has(candidate) || isCandidateGenerated

    if (isFound) {
      return true
    }
  }

  return false
}

/** Every tracked file and every directory that holds one, a directory with its trailing `/`. */
export function treeEntries(trackedFiles) {
  const entries = new Set()

  for (const file of trackedFiles) {
    entries.add(file)
    let directory = posix.dirname(file)

    while (directory !== ".") {
      entries.add(`${directory}/`)
      directory = posix.dirname(directory)
    }
  }

  return entries
}

/** The name of every tracked file, without its directory. */
export function trackedFileNames(trackedFiles) {
  const fileNames = new Set()

  for (const file of trackedFiles) {
    fileNames.add(posix.basename(file))
  }

  return fileNames
}

/** The top-level directories and the file extensions, with their dot, of the tracked files. */
export function treeShape(trackedFiles) {
  const topDirectories = new Set()
  const extensions = new Set()

  for (const file of trackedFiles) {
    const slashIndex = file.indexOf("/")

    if (slashIndex > 0) {
      topDirectories.add(file.slice(0, slashIndex))
    }

    const extension = posix.extname(file)

    if (extension.length > 0) {
      extensions.add(extension)
    }
  }

  return {topDirectories, extensions}
}

/** The missing paths a guidance file at `file` names, each with its line. */
export function missingPaths({file, markdown, trackedFiles}) {
  const {topDirectories, extensions} = treeShape(trackedFiles)
  const entries = treeEntries(trackedFiles)
  const fileNames = trackedFileNames(trackedFiles)
  const directory = posix.dirname(file)
  const failures = []

  for (const span of codeSpans(markdown)) {
    const named = namedPath({text: span.text, topDirectories, extensions})
    const isPath = named.kind === SpanKind.path
    const isException = NOT_REPOSITORY_PATHS[span.text] !== undefined
    const isCheckedPath = isPath && !isException

    if (isCheckedPath) {
      const exists = pathExists({path: named.path, directory, entries, fileNames})

      if (!exists) {
        failures.push({kind: FailureKind.missingPath, file, line: span.line, path: span.text})
      }
    }
  }

  return failures
}

/** The area files the root's area map names, each with its line. */
export function mapEntries(rootMarkdown) {
  const lines = rootMarkdown.split("\n")
  const entries = []
  let isInMap = false

  for (const [index, line] of lines.entries()) {
    if (line === AREA_MAP_HEADING) {
      isInMap = true
    } else if (line.startsWith("#")) {
      isInMap = false
    } else if (isInMap) {
      const match = MAP_ENTRY_PATTERN.exec(line)
      const isEntry = match !== null

      if (isEntry) {
        const isAreaFile = posix.basename(match[1]) === AGENTS_FILE_NAME

        if (isAreaFile) {
          entries.push({path: match[1], line: index + 1})
        }
      }
    }
  }

  return entries
}

/** The area files missing from the map, and the map entries that name no file. */
export function mapFailures({rootMarkdown, trackedFiles}) {
  const entries = mapEntries(rootMarkdown)
  const mapped = new Set()
  const tracked = new Set(trackedFiles)
  const failures = []

  for (const entry of entries) {
    mapped.add(entry.path)

    if (!tracked.has(entry.path)) {
      failures.push({kind: FailureKind.missingAreaFile, file: AGENTS_FILE_NAME, line: entry.line, path: entry.path})
    }
  }

  for (const file of trackedFiles) {
    const isGuidanceFile = posix.basename(file) === AGENTS_FILE_NAME
    const isAreaFile = isGuidanceFile && file !== AGENTS_FILE_NAME
    const isUnmapped = isAreaFile && !mapped.has(file)

    if (isUnmapped) {
      failures.push({kind: FailureKind.unmappedAreaFile, file, line: 1, path: file})
    }
  }

  return failures
}

function kindOf(failure) {
  return failure.kind
}

const CASE_FILES = Object.freeze([
  "AGENTS.md",
  "assets/AGENTS.md",
  "assets/js/app.js",
  "lib/gobusgo/config.ex",
  "lib/gobusgo/one_bus_away/AGENTS.md",
  "lib/gobusgo/one_bus_away/client.ex",
  "mix.exs"
])

const pathCases = [
  {markdown: "`lib/gobusgo/config.ex` and `assets/js/`", kinds: []},
  {markdown: "`lib/gobusgo/configuration.ex`", kinds: [FailureKind.missingPath]},
  {markdown: "`assets/css/`", kinds: [FailureKind.missingPath]},
  {markdown: "`mix.exs` and `client.ex`", kinds: []},
  {markdown: "`server.ex`", kinds: [FailureKind.missingPath]},
  {markdown: "`lib/gobusgo/config.ex/`", kinds: [FailureKind.missingPath]},
  {markdown: "`assets/js/<name>.js` and `lib/*.ex`", kinds: []},
  {markdown: "`assets/css/<name>.css`", kinds: [FailureKind.missingPath]},
  {markdown: "`priv/static/sw.js` and `assets/vendor/maplibre-gl/`", kinds: []},
  {markdown: "`/vehicles`, `/routing/<path>`, and `https://example.org/lib/x.ex`", kinds: []},
  {markdown: "`node lib/missing.mjs`, `Gobusgo.Config.revision/0`, and `oba.routes.state`", kinds: []},
  {markdown: "```sh\nnode `lib/missing.ex`\n```", kinds: []},
  {markdown: "line one\n`lib/missing.ex`", kinds: [FailureKind.missingPath]}
]

for (const {markdown, kinds} of pathCases) {
  const failures = missingPaths({file: "lib/gobusgo/one_bus_away/AGENTS.md", markdown, trackedFiles: CASE_FILES})
  const caseKinds = Array.from(failures, kindOf)
  deepStrictEqual(caseKinds, kinds, markdown)
}

const LINE_CASE_MARKDOWN = "one\n\ntwo `lib/missing.ex`"
const LINE_CASE_LINE = 3
const lineCase = missingPaths({file: "AGENTS.md", markdown: LINE_CASE_MARKDOWN, trackedFiles: CASE_FILES})
deepStrictEqual(lineCase[0].line, LINE_CASE_LINE, "the line of a missing path")

const MAP_HEAD = "# Guide\n\n## Area map\n\nRead these.\n\n"
const MAP_TAIL = "\n\n## Toolchain\n\n- `lib/gobusgo/routing/AGENTS.md`: outside the map.\n"

const mapCases = [
  {
    entries: "- `assets/AGENTS.md`: the front end.\n- `lib/gobusgo/one_bus_away/AGENTS.md`: the integration.",
    kinds: []
  },
  {entries: "- `assets/AGENTS.md`: the front end.", kinds: [FailureKind.unmappedAreaFile]},
  {
    entries: "- `assets/AGENTS.md`: the front end.\n- `lib/gobusgo/one_bus_away/AGENTS.md`: the integration.\n- `lib/gobusgo/gone/AGENTS.md`: removed.",
    kinds: [FailureKind.missingAreaFile]
  }
]

for (const {entries, kinds} of mapCases) {
  const rootMarkdown = `${MAP_HEAD}${entries}${MAP_TAIL}`
  const failures = mapFailures({rootMarkdown, trackedFiles: CASE_FILES})
  const caseKinds = Array.from(failures, kindOf)
  deepStrictEqual(caseKinds, kinds, entries)
}

const missingEntryCase = mapFailures({
  rootMarkdown: `${MAP_HEAD}- \`assets/AGENTS.md\`: one.\n- \`lib/gobusgo/one_bus_away/AGENTS.md\`: two.\n- \`lib/gone/AGENTS.md\`: three.${MAP_TAIL}`,
  trackedFiles: CASE_FILES
})
// The map's heading is line 3 and its first entry line 7, so the third entry is line 9.
const MISSING_ENTRY_LINE = 9
deepStrictEqual(missingEntryCase[0].line, MISSING_ENTRY_LINE, "the line of a map entry that names no file")

for (const exceptions of [GENERATED_PATHS, NOT_REPOSITORY_PATHS]) {
  for (const [path, reason] of Object.entries(exceptions)) {
    deepStrictEqual(reason.length > 0, true, `the reason for the exception ${path}`)
  }
}

// The tree: the files git tracks in this checkout.
const gitOutput = execFileSync("git", ["ls-files", "-z"], {
  cwd: REPOSITORY_ROOT,
  encoding: "utf8",
  maxBuffer: GIT_OUTPUT_BYTES_MAX
})
const trackedFiles = gitOutput.split("\0").filter(isNonEmpty)
const agentsFiles = trackedFiles.filter(isAgentsFile)

function isNonEmpty(text) {
  return text.length > 0
}

function isAgentsFile(file) {
  return posix.basename(file) === AGENTS_FILE_NAME
}

const failures = []

for (const file of agentsFiles) {
  const markdown = readFileSync(new URL(file, REPOSITORY_ROOT), "utf8")

  for (const failure of missingPaths({file, markdown, trackedFiles})) {
    failures.push(failure)
  }
}

const rootMarkdown = readFileSync(new URL(AGENTS_FILE_NAME, REPOSITORY_ROOT), "utf8")

for (const failure of mapFailures({rootMarkdown, trackedFiles})) {
  failures.push(failure)
}

function describe(failure) {
  return `${failure.file}:${failure.line} ${failure.kind} ${failure.path}`
}

const described = Array.from(failures, describe)
deepStrictEqual(described, [], "AGENTS.md failures")
