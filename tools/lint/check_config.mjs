// Checks eslint.config.mjs, eslint.openapi.config.mjs, and
// eslint.core.config.mjs against documents written out by hand: each
// accessibility rule the first turns on still reports its failure, each
// narrowed rule passes over only the tags its exemption names, the second
// reports malformed JSON and a document that breaks the OpenAPI schema, and
// the third reports each kind of async work in a module of the core and
// passes over synchronous code. Run it with `npm run check` in this
// directory; it exits non-zero on the first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {resolve} from "node:path"
import {ESLint} from "eslint"

const eslint = new ESLint({cwd: import.meta.dirname})

// The OpenAPI config runs with the repository root as its base path, as
// `npm run lint:openapi` runs it.
const repositoryRoot = resolve(import.meta.dirname, "..", "..")
const openapiEslint = new ESLint({
  cwd: repositoryRoot,
  overrideConfigFile: resolve(import.meta.dirname, "eslint.openapi.config.mjs")
})

// The core config runs with the repository root as its base path, as
// `npm run lint:core` runs it.
const coreEslint = new ESLint({
  cwd: repositoryRoot,
  overrideConfigFile: resolve(import.meta.dirname, "eslint.core.config.mjs")
})

function documentWith(body) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Page</title>
</head>
<body>
<main>
<h1>Page</h1>
${body}
</main>
</body>
</html>
`
}

function ruleIdOf(message) {
  return message.ruleId
}

async function reportedRules(body) {
  const [result] = await eslint.lintText(documentWith(body), {filePath: "rendered/case.html"})
  const messageRuleIds = Array.from(result.messages, ruleIdOf)
  const ruleIds = Array.from(new Set(messageRuleIds))
  return ruleIds.sort()
}

const cases = [
  {body: "<p>Text</p>", rules: []},
  {body: "<p></p>", rules: ["local/require-content"]},
  {body: `<p role="status"></p>`, rules: []},
  {body: `<p aria-live="polite"></p>`, rules: []},
  {body: `<form phx-submit="go"><button type="submit">Go</button></form>`, rules: []},
  {body: `<form><button type="submit">Go</button></form>`, rules: ["local/require-form-method"]},
  {body: `<button>Go</button>`, rules: ["@html-eslint/require-button-type"]},
  {body: `<input type="text">`, rules: ["@html-eslint/require-input-label"]},
  {body: `<div role="widget">x</div>`, rules: ["@html-eslint/no-abstract-roles", "@html-eslint/no-invalid-role"]},
  {body: `<div role="buton">x</div>`, rules: ["@html-eslint/no-invalid-role"]},
  {body: `<a href="/x" tabindex="2">x</a>`, rules: ["@html-eslint/no-positive-tabindex"]},
  {body: `<button type="button" aria-hidden="true">x</button>`, rules: ["@html-eslint/no-aria-hidden-on-focusable"]},
  {body: `<h3>Skipped</h3>`, rules: ["@html-eslint/no-skip-heading-levels"]},
  {body: `<img src="/i.png">`, rules: ["@html-eslint/require-img-alt"]},
  {body: `<a href="/x"><button type="button">x</button></a>`, rules: ["@html-eslint/no-nested-interactive"]},
  {body: `<details><p>x</p></details>`, rules: ["@html-eslint/require-details-summary"]}
]

for (const {body, rules} of cases) {
  const reported = await reportedRules(body)
  deepStrictEqual(reported, rules, body)
}

const OPENAPI_FILE_PATH = resolve(repositoryRoot, "priv", "openapi.case.json")

const validOpenapi = {openapi: "3.1.0", info: {title: "Case", version: "1"}, paths: {}}

async function reportedOpenapiRules(text) {
  const [result] = await openapiEslint.lintText(text, {filePath: OPENAPI_FILE_PATH})
  const messageRuleIds = Array.from(result.messages, ruleIdOf)
  const ruleIds = Array.from(new Set(messageRuleIds))
  return ruleIds.sort()
}

const SCHEMA_RULE = "local/openapi-schema"

// A syntax error is a fatal message with no rule id.
const openapiCases = [
  {name: "a valid document", text: JSON.stringify(validOpenapi), rules: []},
  {name: "malformed JSON", text: `{"openapi": "3.1.0",`, rules: [null]},
  {name: "a duplicate key", text: `{"openapi": "3.1.0", "info": {"title": "Case", "version": "1"}, "paths": {}, "paths": {}}`, rules: ["json/no-duplicate-keys"]},
  {name: "a missing info", text: JSON.stringify({openapi: "3.1.0", paths: {}}), rules: [SCHEMA_RULE]},
  {name: "a path item that is not an object", text: JSON.stringify({...validOpenapi, paths: {"/x": 5}}), rules: [SCHEMA_RULE]},
  {name: "an unknown top-level key", text: JSON.stringify({...validOpenapi, zz: 1}), rules: [SCHEMA_RULE]},
  {name: "an unknown key in info", text: JSON.stringify({...validOpenapi, info: {...validOpenapi.info, zz: 1}}), rules: [SCHEMA_RULE]},
  {name: "a component schema of an unknown type", text: JSON.stringify({...validOpenapi, components: {schemas: {Case: {type: "strng"}}}}), rules: [SCHEMA_RULE]}
]

for (const {name, text, rules} of openapiCases) {
  const reported = await reportedOpenapiRules(text)
  deepStrictEqual(reported, rules, name)
}

const CORE_FILE_PATH = resolve(repositoryRoot, "assets", "js", "core", "case.js")
const SHELL_FILE_PATH = resolve(repositoryRoot, "assets", "js", "case.js")
const ASYNC_RULE = "local/no-async-work"

async function reportedCoreRules({text, filePath}) {
  const [result] = await coreEslint.lintText(text, {filePath})
  const messageRuleIds = Array.from(result.messages, ruleIdOf)
  const ruleIds = Array.from(new Set(messageRuleIds))
  return ruleIds.sort()
}

const coreCases = [
  {name: "synchronous code", text: "export function sum(values) {\n  let total = 0\n  for (const value of values) {\n    total += value\n  }\n  return total\n}\n", rules: []},
  {name: "a generator", text: "export function* counted(count) {\n  for (let index = 0; index < count; index++) {\n    yield index\n  }\n}\n", rules: []},
  {name: "an async function", text: "export async function read() {\n  return 1\n}\n", rules: [ASYNC_RULE]},
  {name: "an async arrow", text: "export const read = async () => 1\n", rules: [ASYNC_RULE]},
  {name: "an async method", text: "export const reader = {async read() {\n  return 1\n}}\n", rules: [ASYNC_RULE]},
  {name: "a top-level await", text: "export const value = await import(\"./other.js\")\n", rules: [ASYNC_RULE]},
  {name: "a for await", text: "export function drain(source) {\n  return (async () => {\n    for await (const value of source) {\n      console.log(value)\n    }\n  })()\n}\n", rules: [ASYNC_RULE]},
  {name: "a promise", text: "export function later() {\n  return new Promise(function settle(resolve) {\n    resolve(1)\n  })\n}\n", rules: [ASYNC_RULE]},
  {name: "a promise's then", text: "export function next(pending) {\n  return pending.then(function value(result) {\n    return result\n  })\n}\n", rules: [ASYNC_RULE]},
  {name: "a fetch", text: "export function load(path) {\n  return fetch(path)\n}\n", rules: [ASYNC_RULE]},
  {name: "a timer", text: "export function soon(work) {\n  setTimeout(work, 0)\n}\n", rules: [ASYNC_RULE]},
  {name: "a stream", text: "export function expand(bytes) {\n  return new Blob([bytes]).stream().pipeThrough(new DecompressionStream(\"gzip\"))\n}\n", rules: [ASYNC_RULE]},
  {name: "a local binding named like a global", text: "export function load({fetch}) {\n  return fetch\n}\n", rules: []},
  {name: "a property named then", text: "export const step = {then: 1}\n", rules: []},
  {name: "async work outside the core", text: "export async function read() {\n  return await fetch(\"/x\")\n}\n", rules: [], filePath: SHELL_FILE_PATH}
]

for (const {name, text, rules, filePath} of coreCases) {
  let path = CORE_FILE_PATH

  if (filePath !== undefined) {
    path = filePath
  }

  const reported = await reportedCoreRules({text, filePath: path})
  deepStrictEqual(reported, rules, name)
}
