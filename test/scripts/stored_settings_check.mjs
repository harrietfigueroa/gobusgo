// Checks the stored settings module against a storage double written out
// by hand: each key's valid values, a value of the wrong shape, and a
// missing key; the schema version and its migration; the favorites' limit;
// and storage that throws. It also runs the theme script of the service
// worker's offline screen against the same double, so the screen reads the
// key and accepts the values the module does. Run it with
// `node test/scripts/stored_settings_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {ThemeSetting} from "../../assets/js/theme.js"
import {
  FavoriteChangeKind,
  FilterKind,
  SCHEMA_VERSION,
  STORED_THEMES,
  StorageKey,
  migrateValues,
  openStoredSettings
} from "../../assets/js/stored_settings.js"
import {OFFLINE_SCREEN} from "../../assets/js/offline_screen.js"

const COUNT_MAX = 6
const COUNT_PAST_MAX = COUNT_MAX + 1
const VERSION_TEXT = String(SCHEMA_VERSION)
// Under storage that throws: one warning for the migration, one per read
// and per write, and the add and the remove each read before they write.
const THROWING_WARNING_COUNT = 14

// A local storage double over a map of key to text, which counts the
// writes of each key. A missing key reads as null, as Storage's getItem
// returns it.
class MemoryStorage {
  constructor(entries) {
    this.values = new Map(Object.entries(entries))
    this.writeCounts = new Map()
  }

  getItem(key) {
    if (this.values.has(key)) {
      return this.values.get(key)
    } else {
      return null
    }
  }

  setItem(key, value) {
    this.values.set(key, String(value))
    this.countWrite(key)
  }

  removeItem(key) {
    this.values.delete(key)
    this.countWrite(key)
  }

  countWrite(key) {
    const count = this.writeCounts.get(key)

    if (count === undefined) {
      this.writeCounts.set(key, 1)
    } else {
      this.writeCounts.set(key, count + 1)
    }
  }

  entries() {
    return Object.fromEntries(this.values)
  }
}

// A storage double whose every call throws, as a browser that blocks
// storage does.
class ThrowingStorage {
  getItem() {
    throw new Error("storage blocked")
  }

  setItem() {
    throw new Error("storage blocked")
  }

  removeItem() {
    throw new Error("storage blocked")
  }
}

function unreachableStorage() {
  throw new Error("storage blocked")
}

function settingsOver(storage) {
  const warnings = []
  const settings = openStoredSettings({storage: () => storage, warn: (description) => { warnings.push(description) }})
  return {settings, warnings}
}

const favoriteA = {stopId: "1_100", name: "Pine St & 3rd Ave"}
const favoriteB = {stopId: "1_200", name: "Westlake Station"}

function favoritesText(count) {
  const favorites = Array.from({length: count}, favoriteNumbered)
  return JSON.stringify(favorites)
}

function favoriteNumbered(_value, index) {
  return {stopId: `1_${index}`, name: `Stop ${index}`}
}

const themeCases = [
  {name: "light", entries: {[StorageKey.theme]: "light"}, setting: ThemeSetting.light},
  {name: "dark", entries: {[StorageKey.theme]: "dark"}, setting: ThemeSetting.dark},
  {name: "system as text", entries: {[StorageKey.theme]: "system"}, setting: ThemeSetting.system},
  {name: "an unknown theme", entries: {[StorageKey.theme]: "sepia"}, setting: ThemeSetting.system},
  {name: "a missing key", entries: {}, setting: ThemeSetting.system}
]

for (const themeCase of themeCases) {
  const {settings} = settingsOver(new MemoryStorage(themeCase.entries))
  const setting = settings.readTheme()
  deepStrictEqual(setting, themeCase.setting, `theme read: ${themeCase.name}`)
}

const themeWriteCases = [
  {setting: ThemeSetting.light, stored: "light"},
  {setting: ThemeSetting.dark, stored: "dark"},
  {setting: ThemeSetting.system, stored: undefined}
]

for (const writeCase of themeWriteCases) {
  const storage = new MemoryStorage({[StorageKey.theme]: "dark"})
  const {settings} = settingsOver(storage)
  settings.writeTheme(writeCase.setting)
  deepStrictEqual(storage.entries()[StorageKey.theme], writeCase.stored, `theme write: ${writeCase.setting}`)
}

const filter = {agency: ["1"], route: ["1_100479"]}

const filterCases = [
  {name: "a filter", entries: {[StorageKey.vehicleFilter]: JSON.stringify(filter)}, read: {kind: FilterKind.found, filter}, warningCount: 0},
  {name: "JSON null", entries: {[StorageKey.vehicleFilter]: "null"}, read: {kind: FilterKind.none}, warningCount: 0},
  {name: "text that is not JSON", entries: {[StorageKey.vehicleFilter]: "{agency"}, read: {kind: FilterKind.none}, warningCount: 1},
  {name: "a missing key", entries: {}, read: {kind: FilterKind.none}, warningCount: 0}
]

for (const filterCase of filterCases) {
  const {settings, warnings} = settingsOver(new MemoryStorage(filterCase.entries))
  const read = settings.readVehicleFilter()
  deepStrictEqual(read, filterCase.read, `filter read: ${filterCase.name}`)
  deepStrictEqual(warnings.length, filterCase.warningCount, `filter read warnings: ${filterCase.name}`)
}

{
  const storage = new MemoryStorage({})
  const {settings} = settingsOver(storage)
  settings.writeVehicleFilter(filter)
  deepStrictEqual(storage.entries()[StorageKey.vehicleFilter], JSON.stringify(filter), "filter write")
  settings.removeVehicleFilter()
  deepStrictEqual(storage.entries()[StorageKey.vehicleFilter], undefined, "filter remove")
}

const snapCases = [
  {name: "true", entries: {[StorageKey.snapToLocation]: "true"}, snaps: true},
  {name: "false as text", entries: {[StorageKey.snapToLocation]: "false"}, snaps: false},
  {name: "another case", entries: {[StorageKey.snapToLocation]: "TRUE"}, snaps: false},
  {name: "a missing key", entries: {}, snaps: false}
]

for (const snapCase of snapCases) {
  const {settings} = settingsOver(new MemoryStorage(snapCase.entries))
  const snaps = settings.readSnapToLocation()
  deepStrictEqual(snaps, snapCase.snaps, `snap read: ${snapCase.name}`)
}

{
  const storage = new MemoryStorage({})
  const {settings} = settingsOver(storage)
  settings.writeSnapToLocation()
  deepStrictEqual(storage.entries()[StorageKey.snapToLocation], "true", "snap write")
}

const offlineCases = [
  {name: "off", entries: {[StorageKey.offlineSchedules]: "off"}, enabled: false},
  {name: "another text", entries: {[StorageKey.offlineSchedules]: "on"}, enabled: true},
  {name: "a missing key", entries: {}, enabled: true}
]

for (const offlineCase of offlineCases) {
  const {settings} = settingsOver(new MemoryStorage(offlineCase.entries))
  const enabled = settings.readOfflineSchedulesEnabled()
  deepStrictEqual(enabled, offlineCase.enabled, `offline read: ${offlineCase.name}`)
}

const offlineWriteCases = [
  {enabled: false, stored: "off"},
  {enabled: true, stored: undefined}
]

for (const writeCase of offlineWriteCases) {
  const storage = new MemoryStorage({[StorageKey.offlineSchedules]: "off"})
  const {settings} = settingsOver(storage)
  settings.writeOfflineSchedulesEnabled(writeCase.enabled)
  deepStrictEqual(storage.entries()[StorageKey.offlineSchedules], writeCase.stored, `offline write: ${writeCase.enabled}`)
}

const malformedEntries = [{stopId: ""}, {stopId: 7, name: "x"}, {stopId: "1_1"}, null, "1_2", favoriteB]
const extraFieldEntry = {...favoriteA, color: "red"}
const repeatedEntry = {stopId: favoriteA.stopId, name: "Other"}

const favoriteListCases = [
  {name: "two favorites in order", text: JSON.stringify([favoriteA, favoriteB]), countMax: COUNT_MAX, favorites: [favoriteA, favoriteB]},
  {name: "a missing key", text: undefined, countMax: COUNT_MAX, favorites: []},
  {name: "text that is not JSON", text: "[{", countMax: COUNT_MAX, favorites: []},
  {name: "an object, not a list", text: JSON.stringify(favoriteA), countMax: COUNT_MAX, favorites: []},
  {name: "entries of the wrong shape", text: JSON.stringify(malformedEntries), countMax: COUNT_MAX, favorites: [favoriteB]},
  {name: "extra fields", text: JSON.stringify([extraFieldEntry]), countMax: COUNT_MAX, favorites: [favoriteA]},
  {name: "a stop twice", text: JSON.stringify([favoriteA, repeatedEntry]), countMax: COUNT_MAX, favorites: [favoriteA]},
  {name: "more than the limit", text: favoritesText(COUNT_PAST_MAX), countMax: COUNT_MAX, favorites: JSON.parse(favoritesText(COUNT_MAX))},
  {name: "a page with no panel", text: JSON.stringify([favoriteA]), countMax: 0, favorites: []}
]

for (const listCase of favoriteListCases) {
  const entries = {}

  if (listCase.text !== undefined) {
    entries[StorageKey.favoriteStops] = listCase.text
  }

  const {settings} = settingsOver(new MemoryStorage(entries))
  const favorites = settings.listFavorites(listCase.countMax)
  deepStrictEqual(favorites, listCase.favorites, `favorites list: ${listCase.name}`)
}

function storedFavoritesOf(storage) {
  const text = storage.entries()[StorageKey.favoriteStops]
  return JSON.parse(text)
}

{
  const storage = new MemoryStorage({[StorageKey.favoriteStops]: JSON.stringify([favoriteA])})
  const {settings} = settingsOver(storage)
  const added = settings.addFavorite({favorite: favoriteB, countMax: COUNT_MAX})
  deepStrictEqual(added, {kind: FavoriteChangeKind.changed, favorites: [favoriteA, favoriteB]}, "favorites add")
  deepStrictEqual(storedFavoritesOf(storage), [favoriteA, favoriteB], "favorites add stored")
}

{
  const storage = new MemoryStorage({[StorageKey.favoriteStops]: JSON.stringify([favoriteA])})
  const {settings} = settingsOver(storage)
  const added = settings.addFavorite({favorite: favoriteA, countMax: COUNT_MAX})
  deepStrictEqual(added, {kind: FavoriteChangeKind.unchanged}, "favorites add of a favorite")
}

{
  const storage = new MemoryStorage({[StorageKey.favoriteStops]: favoritesText(COUNT_MAX)})
  const {settings} = settingsOver(storage)
  const added = settings.addFavorite({favorite: favoriteA, countMax: COUNT_MAX})
  deepStrictEqual(added, {kind: FavoriteChangeKind.unchanged}, "favorites add past the limit")
  deepStrictEqual(storage.entries()[StorageKey.favoriteStops], favoritesText(COUNT_MAX), "favorites add past the limit stored")
}

{
  const storage = new MemoryStorage({[StorageKey.favoriteStops]: JSON.stringify([favoriteA, favoriteB])})
  const {settings} = settingsOver(storage)
  const removed = settings.removeFavorite({stopId: favoriteA.stopId, countMax: COUNT_MAX})
  deepStrictEqual(removed, {kind: FavoriteChangeKind.changed, favorites: [favoriteB]}, "favorites remove")
  deepStrictEqual(storedFavoritesOf(storage), [favoriteB], "favorites remove stored")
  const unchanged = settings.removeFavorite({stopId: "1_999", countMax: COUNT_MAX})
  deepStrictEqual(unchanged, {kind: FavoriteChangeKind.unchanged}, "favorites remove of no favorite")
}

// Today's values, as a browser stored them before the module existed.
const unversionedEntries = {
  [StorageKey.theme]: "dark",
  [StorageKey.favoriteStops]: JSON.stringify([favoriteA, favoriteB]),
  [StorageKey.vehicleFilter]: JSON.stringify(filter),
  [StorageKey.snapToLocation]: "true",
  [StorageKey.offlineSchedules]: "off"
}

deepStrictEqual(SCHEMA_VERSION, 1, "schema version")

{
  const migrated = migrateValues({version: 0, values: unversionedEntries})
  deepStrictEqual(migrated, unversionedEntries, "migration of unversioned values")
}

{
  const migrated = migrateValues({version: SCHEMA_VERSION, values: unversionedEntries})
  deepStrictEqual(migrated, unversionedEntries, "migration of current values")
}

{
  const storage = new MemoryStorage(unversionedEntries)
  const {settings} = settingsOver(storage)
  settings.readTheme()
  settings.listFavorites(COUNT_MAX)
  settings.readSnapToLocation()
  const expected = {...unversionedEntries, [StorageKey.schemaVersion]: VERSION_TEXT}
  deepStrictEqual(storage.entries(), expected, "first use stores the version and changes no value")
  deepStrictEqual(storage.writeCounts.get(StorageKey.schemaVersion), 1, "migration runs once")
}

{
  const storage = new MemoryStorage({})
  const {settings} = settingsOver(storage)
  settings.readOfflineSchedulesEnabled()
  deepStrictEqual(storage.entries(), {[StorageKey.schemaVersion]: VERSION_TEXT}, "first use of empty storage stores the version only")
}

{
  const entries = {...unversionedEntries, [StorageKey.schemaVersion]: VERSION_TEXT}
  const storage = new MemoryStorage(entries)
  const {settings} = settingsOver(storage)
  settings.readTheme()
  deepStrictEqual(storage.writeCounts.size, 0, "current version writes nothing")
}

{
  const entries = {...unversionedEntries, [StorageKey.schemaVersion]: String(SCHEMA_VERSION + 1)}
  const storage = new MemoryStorage(entries)
  const {settings} = settingsOver(storage)
  const setting = settings.readTheme()
  deepStrictEqual(setting, ThemeSetting.dark, "a later version reads the values it can")
  deepStrictEqual(storage.entries(), entries, "a later version is left as it is")
}

{
  const storage = new MemoryStorage({...unversionedEntries, [StorageKey.schemaVersion]: "one"})
  const {settings} = settingsOver(storage)
  settings.readTheme()
  deepStrictEqual(storage.entries()[StorageKey.schemaVersion], VERSION_TEXT, "an unreadable version migrates as unversioned")
}

const throwingCases = [
  {name: "storage whose calls throw", storage: () => new ThrowingStorage()},
  {name: "storage that cannot be reached", storage: unreachableStorage}
]

for (const throwingCase of throwingCases) {
  const warnings = []
  const settings = openStoredSettings({storage: throwingCase.storage, warn: (description) => { warnings.push(description) }})
  const theme = settings.readTheme()
  const read = settings.readVehicleFilter()
  const snaps = settings.readSnapToLocation()
  const enabled = settings.readOfflineSchedulesEnabled()
  const favorites = settings.listFavorites(COUNT_MAX)
  settings.writeTheme(ThemeSetting.dark)
  settings.writeVehicleFilter(filter)
  settings.removeVehicleFilter()
  settings.writeSnapToLocation()
  settings.writeOfflineSchedulesEnabled(false)
  const added = settings.addFavorite({favorite: favoriteA, countMax: COUNT_MAX})
  const removed = settings.removeFavorite({stopId: favoriteA.stopId, countMax: COUNT_MAX})

  deepStrictEqual(theme, ThemeSetting.system, `${throwingCase.name}: theme`)
  deepStrictEqual(read, {kind: FilterKind.none}, `${throwingCase.name}: filter`)
  deepStrictEqual(snaps, false, `${throwingCase.name}: snap`)
  deepStrictEqual(enabled, true, `${throwingCase.name}: offline`)
  deepStrictEqual(favorites, [], `${throwingCase.name}: favorites`)
  deepStrictEqual(added, {kind: FavoriteChangeKind.changed, favorites: [favoriteA]}, `${throwingCase.name}: add`)
  deepStrictEqual(removed, {kind: FavoriteChangeKind.unchanged}, `${throwingCase.name}: remove`)
  deepStrictEqual(warnings.length, THROWING_WARNING_COUNT, `${throwingCase.name}: warnings`)
}

// The theme script of the offline screen, run against a storage double and
// a document double.
const scriptMatch = OFFLINE_SCREEN.match(/<script>([\s\S]*?)<\/script>/)
const offlineThemeScript = new Function("localStorage", "document", scriptMatch[1])

function offlineScreenTheme(storage) {
  const document = {documentElement: {dataset: {}}}
  offlineThemeScript(storage, document)
  return document.documentElement.dataset.theme
}

deepStrictEqual(STORED_THEMES, [ThemeSetting.light, ThemeSetting.dark], "stored themes")

for (const themeCase of themeCases) {
  const {settings} = settingsOver(new MemoryStorage(themeCase.entries))
  const setting = settings.readTheme()
  let expected = undefined

  if (STORED_THEMES.includes(setting)) {
    expected = setting
  }

  const storage = new MemoryStorage(themeCase.entries)
  const theme = offlineScreenTheme(storage)
  deepStrictEqual(theme, expected, `offline screen theme: ${themeCase.name}`)
}

{
  const storage = new ThrowingStorage()
  const theme = offlineScreenTheme(storage)
  deepStrictEqual(theme, undefined, "offline screen theme: storage that throws")
}

console.log("stored settings check passed")
