// Checks eslint.config.mjs against documents written out by hand: each
// accessibility rule it turns on still reports its failure, and each
// narrowed rule passes over only the tags its exemption names. Run it with
// `npm run check` in this directory; it exits non-zero on the first case
// that differs.

import {deepStrictEqual} from "node:assert/strict"
import {ESLint} from "eslint"

const eslint = new ESLint({cwd: import.meta.dirname})

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
