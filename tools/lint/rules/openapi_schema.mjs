// A rule that validates a whole JSON document against one JSON Schema
// 2020-12 file, compiled once with Ajv's 2020 dialect so that
// `unevaluatedProperties` and `$dynamicRef` are enforced. The schema is read
// from disk and holds no external reference, so no validation makes a
// network request.

import {readFileSync} from "node:fs"
import {resolve} from "node:path"
import Ajv2020 from "ajv/dist/2020.js"
import addFormats from "ajv-formats"

const PATH_SEPARATOR = "/"

function unescapePointerToken(token) {
  return token.replaceAll("~1", "/").replaceAll("~0", "~")
}

function pointerTokens(instancePath) {
  if (instancePath === "") {
    return []
  }

  const tokens = instancePath.split(PATH_SEPARATOR).slice(1)
  return Array.from(tokens, unescapePointerToken)
}

// The member or element of a momoa node that a pointer token names, or
// `undefined` where the node has no such child.
function childOf({node, token}) {
  if (node.type === "Object") {
    const member = node.members.find((candidate) => candidate.name.value === token)
    return member === undefined ? undefined : member.value
  }

  if (node.type === "Array") {
    const element = node.elements[Number(token)]
    return element === undefined ? undefined : element.value
  }

  return undefined
}

// The deepest node the pointer reaches; the document's root where it
// reaches none. An unknown-field error names the parent's path, so it
// is reported at the parent.
function nodeAt({root, instancePath}) {
  let node = root

  for (const token of pointerTokens(instancePath)) {
    const child = childOf({node, token})

    if (child === undefined) {
      return node
    }

    node = child
  }

  return node
}

function messageOf(error) {
  const location = error.instancePath === "" ? "Root" : error.instancePath
  const detail = Object.keys(error.params).length === 0 ? "" : ` ${JSON.stringify(error.params)}`
  return `${location} ${error.message}${detail}`
}

const DYNAMIC_REF_META = "#meta"
const JSON_SCHEMA_DIALECT = "https://json-schema.org/draft/2020-12/schema"

// Ajv resolves a `$dynamicRef` only to an anchor at the root of the schema,
// and the OpenAPI schema's `meta` anchor sits under `$defs`, so Ajv sends
// each Schema Object back to the root schema, which rejects every keyword
// of a Schema Object. The anchor is the hook where a dialect states what a
// Schema Object is; the OpenAPI dialect is JSON Schema 2020-12, which Ajv
// ships, so each such reference is rewritten to point at it. The copy is
// walked with an explicit stack, bounded by the size of the schema.
function withDialectForDynamicRefs(schema) {
  const copy = structuredClone(schema)
  const pending = [copy]

  while (pending.length > 0) {
    const node = pending.pop()

    if (node.$dynamicRef === DYNAMIC_REF_META) {
      delete node.$dynamicRef
      node.$ref = JSON_SCHEMA_DIALECT
    }

    for (const child of Object.values(node)) {
      if (typeof child === "object" && child !== null) {
        pending.push(child)
      }
    }
  }

  return copy
}

function compile({schemaPath, cwd}) {
  const schema = JSON.parse(readFileSync(resolve(cwd, schemaPath), "utf8"))
  const resolved = withDialectForDynamicRefs(schema)

  // The OpenAPI schema carries annotation keywords and a `$comment` per
  // object that Ajv's strict mode rejects.
  const ajv = new Ajv2020({allErrors: true, strict: false})
  addFormats(ajv)

  // The schema names `media-range` for a media type pattern; no Ajv format
  // package implements it, so it is declared as an annotation.
  ajv.addFormat("media-range", true)
  return ajv.compile(resolved)
}

const compiledByPath = new Map()

// One compiled validator per schema file for the whole lint run, since the
// rule is created once for every linted file.
function compiledFor({schemaPath, cwd}) {
  const key = resolve(cwd, schemaPath)
  const cached = compiledByPath.get(key)

  if (cached !== undefined) {
    return cached
  }

  const validate = compile({schemaPath, cwd})
  compiledByPath.set(key, validate)
  return validate
}

const rule = {
  meta: {
    type: "problem",
    schema: [
      {
        type: "object",
        properties: {schemaPath: {type: "string"}},
        required: ["schemaPath"],
        additionalProperties: false
      }
    ],
    messages: {invalid: "{{message}}"}
  },
  create(context) {
    const validate = compiledFor({schemaPath: context.options[0].schemaPath, cwd: context.cwd})

    return {
      Document(document) {
        const value = JSON.parse(context.sourceCode.text)

        if (validate(value)) {
          return
        }

        for (const error of validate.errors) {
          const node = nodeAt({root: document.body, instancePath: error.instancePath})
          context.report({loc: node.loc, messageId: "invalid", data: {message: messageOf(error)}})
        }
      }
    }
  }
}

export default {rules: {"openapi-schema": rule}}
