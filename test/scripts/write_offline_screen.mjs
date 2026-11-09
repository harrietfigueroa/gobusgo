// Writes the offline screen the service worker answers with to
// tools/lint/rendered/, beside the pages the server renders, for html-eslint.

import {mkdirSync, writeFileSync} from "node:fs"
import {OFFLINE_SCREEN} from "../../assets/js/offline_screen.js"

const outputDirectory = new URL("../../tools/lint/rendered/", import.meta.url)

mkdirSync(outputDirectory, {recursive: true})
writeFileSync(new URL("offline-screen.html", outputDirectory), OFFLINE_SCREEN)
