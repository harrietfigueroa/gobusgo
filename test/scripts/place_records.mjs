// Turns the places records of the places build, `{sourceDate, categories,
// places: [[name, [aliases], latitudeMicrodegrees, longitudeMicrodegrees,
// categoryIndex, prominence, area], …]}`, into the table the place search
// indexes. Everything here is pure.

const NAME = 0
const ALIASES = 1
const LATITUDE = 2
const LONGITUDE = 3
const CATEGORY = 4
const PROMINENCE = 5
const AREA = 6

/** The table of columns that a place search indexes, from the records of the places build. */
export function tableOfRecords(records) {
  const places = records.places
  const placeCount = places.length
  const names = []
  const aliasNames = []
  const aliasStarts = new Uint32Array(placeCount + 1)
  const latitudeMicrodegrees = new Int32Array(placeCount)
  const longitudeMicrodegrees = new Int32Array(placeCount)
  const categories = new Uint8Array(placeCount)
  const prominences = new Uint8Array(placeCount)
  const areas = new Uint8Array(placeCount)

  for (let placeIndex = 0; placeIndex < placeCount; placeIndex++) {
    const place = places[placeIndex]
    names.push(place[NAME])
    aliasStarts[placeIndex] = aliasNames.length

    for (const alias of place[ALIASES]) {
      aliasNames.push(alias)
    }

    latitudeMicrodegrees[placeIndex] = place[LATITUDE]
    longitudeMicrodegrees[placeIndex] = place[LONGITUDE]
    categories[placeIndex] = place[CATEGORY]
    prominences[placeIndex] = place[PROMINENCE]
    areas[placeIndex] = place[AREA]
  }

  aliasStarts[placeCount] = aliasNames.length

  return {
    placeCount,
    names,
    aliasStarts,
    aliasNames,
    latitudeMicrodegrees,
    longitudeMicrodegrees,
    categories,
    prominences,
    areas,
    categoryNames: records.categories
  }
}

const COLUMN_NAMES = ["aliasStarts", "latitudeMicrodegrees", "longitudeMicrodegrees", "categories", "prominences", "areas"]

/** The table with each typed column as a plain array, which JSON carries. */
export function jsonColumnsOfTable(table) {
  const columns = {placeCount: table.placeCount, names: table.names, aliasNames: table.aliasNames, categoryNames: table.categoryNames}

  for (const column of COLUMN_NAMES) {
    columns[column] = Array.from(table[column])
  }

  return columns
}

/** The table of the columns `jsonColumnsOfTable` wrote. */
export function tableOfJsonColumns(columns) {
  return {
    placeCount: columns.placeCount,
    names: columns.names,
    aliasStarts: Uint32Array.from(columns.aliasStarts),
    aliasNames: columns.aliasNames,
    latitudeMicrodegrees: Int32Array.from(columns.latitudeMicrodegrees),
    longitudeMicrodegrees: Int32Array.from(columns.longitudeMicrodegrees),
    categories: Uint8Array.from(columns.categories),
    prominences: Uint8Array.from(columns.prominences),
    areas: Uint8Array.from(columns.areas),
    categoryNames: columns.categoryNames
  }
}
