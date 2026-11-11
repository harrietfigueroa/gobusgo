// The JSON syntax rules and the OpenAPI 3.1 schema over the OpenAPI
// documents in priv/. The documents sit outside this directory, and a file
// outside the directory of the config that names it is ignored, so this
// config is run from the repository root with `--config`, which makes the
// root its base path: `npm run lint:openapi` does so.
// https://spec.openapis.org/oas/3.1/schema/2025-11-23 — checked 2026-11-11

import json from "@eslint/json"
import validator from "eslint-plugin-json-schema-validator"

const OPENAPI_FILES = ["priv/openapi*.json"]

// The plugin compiles the schema with Ajv's draft-07 dialect and ignores a
// keyword it does not know, so `unevaluatedProperties` and `$dynamicRef`
// of the 2020-12 schema check nothing: required fields, types, patterns,
// and enums of the OpenAPI objects are checked, an unknown field and the
// contents of a Schema Object are not.
const openapiSchemaOptions = {
  // The schema catalog is fetched over the network.
  useSchemastoreCatalog: false,
  schemas: [{fileMatch: OPENAPI_FILES, schema: "tools/lint/schemas/openapi-3.1.json"}]
}

export default [
  {
    files: OPENAPI_FILES,
    language: "json/json",
    plugins: {json, "json-schema-validator": validator},
    rules: {
      ...json.configs.recommended.rules,
      "json-schema-validator/no-invalid": ["error", openapiSchemaOptions]
    }
  }
]
