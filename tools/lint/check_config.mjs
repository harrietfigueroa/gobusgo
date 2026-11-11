// Checks eslint.config.mjs and eslint.openapi.config.mjs against documents
// written out by hand: each accessibility rule the first turns on still
// reports its failure, each narrowed rule passes over only the tags its
// exemption names, and the second reports malformed JSON and a document
// that breaks the OpenAPI schema. Run it with `npm run check` in this
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
