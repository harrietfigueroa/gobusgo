// Writes the golden fixture test/fixtures/walk_links/v1/expected.json from the
// browser's core, over the shards of test/fixtures/walk_graph/v1/. Run it with
// `node test/scripts/walk_links_fixtures.mjs` after a change to the path
// search or to the queries of walk_links_queries.mjs.

import {mkdirSync, writeFileSync} from "node:fs"
import {fileURLToPath} from "node:url"
import {goldenQueries} from "./walk_links_queries.mjs"

const directory = fileURLToPath(new URL("../fixtures/walk_links/v1/", import.meta.url))
mkdirSync(directory, {recursive: true})
writeFileSync(directory + "expected.json", JSON.stringify(goldenQueries(), null, 1) + "\n")
