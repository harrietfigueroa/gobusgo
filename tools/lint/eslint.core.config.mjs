// The rule that keeps the core synchronous, over every module of
// assets/js/core/. The modules sit outside this directory, and a file
// outside the directory of the config that names it is ignored, so this
// config is run from the repository root with `--config`, which makes the
// root its base path: `npm run lint:core` does so.

import noAsyncWork from "./rules/no_async_work.mjs"

export default [
  {
    files: ["assets/js/core/**/*.js"],
    languageOptions: {ecmaVersion: "latest", sourceType: "module"},
    plugins: {local: noAsyncWork},
    rules: {"local/no-async-work": "error"}
  }
]
