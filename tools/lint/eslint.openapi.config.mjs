// The JSON syntax rules and the OpenAPI 3.1 schema over the OpenAPI
// documents in priv/. The documents sit outside this directory, and a file
// outside the directory of the config that names it is ignored, so this
// config is run from the repository root with `--config`, which makes the
// root its base path: `npm run lint:openapi` does so.
// https://spec.openapis.org/oas/3.1/schema/2025-11-23 — checked 2026-11-11
//
// The schema is JSON Schema 2020-12 and is compiled by Ajv's 2020 dialect,
// so required fields, types, patterns, enums, unknown fields
// (`unevaluatedProperties`), and the contents of Schema Objects
// (`$dynamicRef` to the dialect's meta-schema, which the schema leaves
// open) are checked. The schema-base variant is not used: it names a
// remote dialect and the Schema Object check above is the base schema's.

import json from "@eslint/json"
import openapiSchema from "./rules/openapi_schema.mjs"

export default [
  {
    files: ["priv/openapi*.json"],
    language: "json/json",
    plugins: {json, local: openapiSchema},
    rules: {
      ...json.configs.recommended.rules,
      "local/openapi-schema": ["error", {schemaPath: "tools/lint/schemas/openapi-3.1.json"}]
    }
  }
]
