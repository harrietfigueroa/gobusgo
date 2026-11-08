// Serves the browser benchmark to a phone on the same network: the page, the
// engine, the snapshot reader, and the benchmark data, and nothing else of
// the repository, so no other file is reachable.
// Run it with `node bench/serve.mjs` from the experiment directory and open
// the address it prints on the phone.

import {createServer} from "node:http"
import {readFile} from "node:fs/promises"
import {networkInterfaces} from "node:os"
import {fileURLToPath} from "node:url"
import {extname, join, normalize} from "node:path"

const PORT = 8232
const OK = 200
const NOT_FOUND = 404
const repository = fileURLToPath(new URL("../../../", import.meta.url))
const ALLOWED_PREFIXES = ["experiments/routing/bench/", "experiments/routing/engine/", "experiments/routing/data/"]
const ALLOWED_FILES = ["assets/js/routing_snapshot.js"]
const CONTENT_TYPES = {".html": "text/html", ".js": "text/javascript", ".mjs": "text/javascript", ".json": "application/json", ".bin": "application/octet-stream"}

function isAllowed(path) {
  const isAllowedFile = ALLOWED_FILES.includes(path)
  const isUnderPrefix = ALLOWED_PREFIXES.some(prefix => path.startsWith(prefix))
  return isAllowedFile || isUnderPrefix
}

async function answer(request, response) {
  const path = normalize(decodeURIComponent(new URL(request.url, "http://localhost").pathname)).replace(/^\/+/, "")
  const isServed = isAllowed(path) && !path.includes("..")

  if (!isServed) {
    response.writeHead(NOT_FOUND).end()
    return
  }

  try {
    const body = await readFile(join(repository, path))
    let contentType = "application/octet-stream"

    if (Object.hasOwn(CONTENT_TYPES, extname(path))) {
      contentType = CONTENT_TYPES[extname(path)]
    }

    response.writeHead(OK, {"content-type": contentType, "cache-control": "no-store"})
    response.end(body)
  } catch (error) {
    if (error.code === "ENOENT") {
      response.writeHead(NOT_FOUND).end()
      return
    }

    throw error
  }
}

function printAddresses() {
  for (const addresses of Object.values(networkInterfaces())) {
    for (const address of addresses) {
      const isLanAddress = address.family === "IPv4" && !address.internal

      if (isLanAddress) {
        console.log("http://" + address.address + ":" + PORT + "/experiments/routing/bench/index.html")
      }
    }
  }
}

createServer(answer).listen(PORT, "0.0.0.0", printAddresses)
