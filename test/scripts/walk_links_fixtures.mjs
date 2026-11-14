// Writes the golden file of the walk queries from the browser's core. Run it
// with `node test/scripts/walk_links_fixtures.mjs` after a change to the path
// search or to the queries.

import {mkdirSync, writeFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {goldenQueries} from "./walk_links_queries.mjs"

const JSON_INDENT = 1
const directory = fileURLToPath(new URL("../fixtures/walk_links/v1/", import.meta.url))
mkdirSync(directory, {recursive: true})
writeFileSync(directory + "expected.json", JSON.stringify(goldenQueries(), null, JSON_INDENT) + "\n")
