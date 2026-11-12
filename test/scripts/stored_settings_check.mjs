// Checks the stored settings module against a storage double written out
// by hand: each key's valid values, a value of the wrong shape, and a
// missing key; the schema version and its migration; the favorites' limit
// and their order, moved to each index and read again by a page loaded
// anew; the recent trips' shapes, order, and limit; and storage that throws. It also runs the theme script of the service
// worker's offline screen against the same double, so the screen reads the
// key and accepts the values the module does, and sets the theme color of
// the theme each setting resolves to on a light and on a dark system. Run it with
// `node test/scripts/stored_settings_check.mjs`; it exits non-zero on the
// first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {AssertionError} from "../../assets/js/core/assert.js"
import {resolveTheme, Theme, themeColor, ThemeSetting} from "../../assets/js/theme.js"
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
// and per write, and the adds and the remove each read before they write.
const THROWING_WARNING_COUNT = 23

// Every key the module reads, each held as null until it is written, since
// Storage's getItem answers null for a key it does not hold.
// https://html.spec.whatwg.org/multipage/webstorage.html#dom-storage-getitem — checked 2026-11-08
const storageKeys = Object.values(StorageKey)
const absentPairs = Array.from(storageKeys, absentEntry)
const absentEntries = Object.fromEntries(absentPairs)

function absentEntry(key) {
  return [key, null]
}

// A local storage double over a map of key to text, which counts the
// writes of each key.
class MemoryStorage {
  constructor(entries) {
    this.values = new Map(Object.entries({...absentEntries, ...entries}))
    this.writeCounts = new Map()
  }

  getItem(key) {
    return this.values.get(key)
  }

  setItem(key, value) {
    this.values.set(key, String(value))
    this.countWrite(key)
  }

  removeItem(key) {
    this.values.set(key, null)
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

  // The keys the double holds a text for, as Storage lists its keys.
  entries() {
    const held = {}

    for (const [key, value] of this.values) {
      if (value !== null) {
        held[key] = value
      }
    }

    return held
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

const followCases = [
  {name: "true", entries: {[StorageKey.locationFollow]: "true"}, isOn: true},
  {name: "false as text", entries: {[StorageKey.locationFollow]: "false"}, isOn: false},
  {name: "another case", entries: {[StorageKey.locationFollow]: "TRUE"}, isOn: false},
  {name: "a missing key", entries: {}, isOn: false}
]

deepStrictEqual(StorageKey.locationFollow, "gobusgo:snap-to-location", "the location button keeps the snap's key")

for (const followCase of followCases) {
  const {settings} = settingsOver(new MemoryStorage(followCase.entries))
  const isOn = settings.readLocationFollow()
  deepStrictEqual(isOn, followCase.isOn, `location button read: ${followCase.name}`)
}

{
  const storage = new MemoryStorage({})
  const {settings} = settingsOver(storage)
  settings.writeLocationFollow(true)
  deepStrictEqual(storage.entries()[StorageKey.locationFollow], "true", "location button left on")
  settings.writeLocationFollow(false)
  deepStrictEqual(storage.entries()[StorageKey.locationFollow], undefined, "location button turned off")
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

const showDirectionCases = [
  {name: "off", entries: {[StorageKey.showDirection]: "off"}, isShown: false},
  {name: "another text", entries: {[StorageKey.showDirection]: "on"}, isShown: true},
  {name: "a missing key", entries: {}, isShown: true}
]

deepStrictEqual(StorageKey.showDirection, "gobusgo:show-direction", "the direction setting's key")

for (const showCase of showDirectionCases) {
  const {settings} = settingsOver(new MemoryStorage(showCase.entries))
  const isShown = settings.readShowDirection()
  deepStrictEqual(isShown, showCase.isShown, `direction setting read: ${showCase.name}`)
}

const showDirectionWriteCases = [
  {isShown: false, stored: "off"},
  {isShown: true, stored: undefined}
]

for (const writeCase of showDirectionWriteCases) {
  const storage = new MemoryStorage({[StorageKey.showDirection]: "off"})
  const {settings} = settingsOver(storage)
  settings.writeShowDirection(writeCase.isShown)
  deepStrictEqual(storage.entries()[StorageKey.showDirection], writeCase.stored, `direction setting write: ${writeCase.isShown}`)
}

const motionDenialCases = [
  {name: "denied", entries: {[StorageKey.motionPermission]: "denied"}, isDenied: true},
  {name: "another text", entries: {[StorageKey.motionPermission]: "granted"}, isDenied: false},
  {name: "a missing key", entries: {}, isDenied: false}
]

deepStrictEqual(StorageKey.motionPermission, "gobusgo:motion-permission", "the motion denial's key")

for (const denialCase of motionDenialCases) {
  const {settings} = settingsOver(new MemoryStorage(denialCase.entries))
  const isDenied = settings.readMotionPermissionDenied()
  deepStrictEqual(isDenied, denialCase.isDenied, `motion denial read: ${denialCase.name}`)
}

{
  const storage = new MemoryStorage({})
  const {settings} = settingsOver(storage)
  settings.writeMotionPermissionDenied()
  deepStrictEqual(storage.entries()[StorageKey.motionPermission], "denied", "motion denial stored")
}

const sharedVehicleCases = [
  {name: "on", entries: {[StorageKey.sharedVehicles]: "on"}, shown: true},
  {name: "another text", entries: {[StorageKey.sharedVehicles]: "true"}, shown: false},
  {name: "a missing key", entries: {}, shown: false}
]

for (const sharedVehicleCase of sharedVehicleCases) {
  const {settings} = settingsOver(new MemoryStorage(sharedVehicleCase.entries))
  const shown = settings.readSharedVehiclesShown()
  deepStrictEqual(shown, sharedVehicleCase.shown, `shared vehicles read: ${sharedVehicleCase.name}`)
}

const sharedVehicleWriteCases = [
  {shown: true, stored: "on"},
  {shown: false, stored: undefined}
]

for (const writeCase of sharedVehicleWriteCases) {
  const storage = new MemoryStorage({[StorageKey.sharedVehicles]: "on"})
  const {settings} = settingsOver(storage)
  settings.writeSharedVehiclesShown(writeCase.shown)
  deepStrictEqual(storage.entries()[StorageKey.sharedVehicles], writeCase.stored, `shared vehicles write: ${writeCase.shown}`)
}

const offlineBasemapCases = [
  {name: "on", entries: {[StorageKey.offlineBasemap]: "on"}, enabled: true},
  {name: "another text", entries: {[StorageKey.offlineBasemap]: "true"}, enabled: false},
  {name: "a missing key, the default", entries: {}, enabled: false}
]

for (const offlineBasemapCase of offlineBasemapCases) {
  const {settings} = settingsOver(new MemoryStorage(offlineBasemapCase.entries))
  const enabled = settings.readOfflineBasemapEnabled()
  deepStrictEqual(enabled, offlineBasemapCase.enabled, `offline basemap read: ${offlineBasemapCase.name}`)
}

const offlineBasemapWriteCases = [
  {enabled: true, stored: "on"},
  {enabled: false, stored: undefined}
]

for (const writeCase of offlineBasemapWriteCases) {
  const storage = new MemoryStorage({[StorageKey.offlineBasemap]: "on"})
  const {settings} = settingsOver(storage)
  settings.writeOfflineBasemapEnabled(writeCase.enabled)
  deepStrictEqual(storage.entries()[StorageKey.offlineBasemap], writeCase.stored, `offline basemap write: ${writeCase.enabled}`)
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

const favoriteC = {stopId: "1_300", name: "Othello Station"}
const threeFavorites = [favoriteA, favoriteB, favoriteC]

// Every move of every favorite of three to every index, with the order the
// list then holds.
const moveCases = [
  {stopId: favoriteA.stopId, index: 1, favorites: [favoriteB, favoriteA, favoriteC]},
  {stopId: favoriteA.stopId, index: 2, favorites: [favoriteB, favoriteC, favoriteA]},
  {stopId: favoriteB.stopId, index: 0, favorites: [favoriteB, favoriteA, favoriteC]},
  {stopId: favoriteB.stopId, index: 2, favorites: [favoriteA, favoriteC, favoriteB]},
  {stopId: favoriteC.stopId, index: 0, favorites: [favoriteC, favoriteA, favoriteB]},
  {stopId: favoriteC.stopId, index: 1, favorites: [favoriteA, favoriteC, favoriteB]}
]

for (const moveCase of moveCases) {
  const name = `favorites move of ${moveCase.stopId} to ${moveCase.index}`
  const storage = new MemoryStorage({[StorageKey.favoriteStops]: JSON.stringify(threeFavorites)})
  const {settings} = settingsOver(storage)
  const moved = settings.moveFavorite({stopId: moveCase.stopId, index: moveCase.index, countMax: COUNT_MAX})
  deepStrictEqual(moved, {kind: FavoriteChangeKind.changed, favorites: moveCase.favorites}, name)
  deepStrictEqual(storedFavoritesOf(storage), moveCase.favorites, `${name} stored`)

  // A page loaded again opens a module of its own over the same storage.
  const {settings: reloaded} = settingsOver(storage)
  deepStrictEqual(reloaded.listFavorites(COUNT_MAX), moveCase.favorites, `${name} after a reload`)
}

const unchangedMoveCases = [
  {name: "to where it stands", stopId: favoriteB.stopId, index: 1},
  {name: "of no favorite", stopId: "1_999", index: 0}
]

for (const moveCase of unchangedMoveCases) {
  const storage = new MemoryStorage({[StorageKey.favoriteStops]: JSON.stringify(threeFavorites)})
  const {settings} = settingsOver(storage)
  const moved = settings.moveFavorite({stopId: moveCase.stopId, index: moveCase.index, countMax: COUNT_MAX})
  deepStrictEqual(moved, {kind: FavoriteChangeKind.unchanged}, `favorites move ${moveCase.name}`)
  deepStrictEqual(storage.writeCounts.get(StorageKey.favoriteStops), undefined, `favorites move ${moveCase.name} writes nothing`)
}

{
  const storage = new MemoryStorage({[StorageKey.favoriteStops]: JSON.stringify(threeFavorites)})
  const {settings} = settingsOver(storage)
  const moved = settings.moveFavorite({stopId: favoriteA.stopId, index: threeFavorites.length, countMax: COUNT_MAX})
  deepStrictEqual(moved, {kind: FavoriteChangeKind.changed, favorites: [favoriteB, favoriteC, favoriteA]}, "favorites move past the end")
}

{
  const storage = new MemoryStorage({[StorageKey.favoriteStops]: JSON.stringify(threeFavorites)})
  const {settings} = settingsOver(storage)
  settings.moveFavorite({stopId: favoriteC.stopId, index: 0, countMax: COUNT_MAX})
  const favoriteD = {stopId: "1_400", name: "Mount Baker Station"}
  const added = settings.addFavorite({favorite: favoriteD, countMax: COUNT_MAX})
  const expected = [favoriteC, favoriteA, favoriteB, favoriteD]
  deepStrictEqual(added, {kind: FavoriteChangeKind.changed, favorites: expected}, "favorites add after a move appends")
}

const NEGATIVE_INDEX = -1
const FRACTIONAL_INDEX = 0.5

for (const index of [NEGATIVE_INDEX, FRACTIONAL_INDEX, Number.NaN]) {
  const {settings} = settingsOver(new MemoryStorage({[StorageKey.favoriteStops]: JSON.stringify(threeFavorites)}))
  throws(() => settings.moveFavorite({stopId: favoriteA.stopId, index, countMax: COUNT_MAX}), AssertionError, `favorites move to ${index} asserts`)
}

// Today's values, as a browser stored them before the module existed.
const unversionedEntries = {
  [StorageKey.theme]: "dark",
  [StorageKey.favoriteStops]: JSON.stringify([favoriteA, favoriteB]),
  [StorageKey.vehicleFilter]: JSON.stringify(filter),
  [StorageKey.locationFollow]: "true",
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
  settings.readLocationFollow()
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

// The recent trips: each trip's two ends as the Trip tab holds them, most
// recent first, the newest added in front with an earlier copy of it
// dropped, at most the limit, and an entry of another shape left out.
const RECENT_COUNT_MAX = 3
const locationEnd = {kind: "location"}
const stopEndA = {kind: "stop", stopId: "1_100", name: "Westlake Station"}
const pointEndA = {kind: "point", name: "Pike Place Market", lat: 47.6094, lon: -122.3422}
const tripA = {from: locationEnd, to: pointEndA}
const tripB = {from: pointEndA, to: stopEndA}
const tripC = {from: stopEndA, to: pointEndA}
const malformedTrips = [
  {from: locationEnd},
  {from: locationEnd, to: {kind: "point", name: "Off the globe", lat: 91, lon: 0}},
  {from: locationEnd, to: {kind: "stop", stopId: "", name: "x"}},
  {from: {kind: "none"}, to: stopEndA},
  {from: locationEnd, to: locationEnd},
  null,
  tripB
]

const recentListCases = [
  {name: "two trips in order", text: JSON.stringify([tripA, tripB]), trips: [tripA, tripB]},
  {name: "a missing key", text: undefined, trips: []},
  {name: "text that is not JSON", text: "[{", trips: []},
  {name: "an object, not a list", text: JSON.stringify(tripA), trips: []},
  {name: "entries of the wrong shape", text: JSON.stringify(malformedTrips), trips: [tripB]},
  {name: "extra fields", text: JSON.stringify([{...tripA, at: 1, to: {...pointEndA, source: "osm"}}]), trips: [tripA]},
  {name: "a trip twice", text: JSON.stringify([tripA, tripA]), trips: [tripA]},
  {name: "more than the limit", text: JSON.stringify([tripA, tripB, tripC, {from: locationEnd, to: stopEndA}]), trips: [tripA, tripB, tripC]}
]

for (const listCase of recentListCases) {
  const entries = {}

  if (listCase.text !== undefined) {
    entries[StorageKey.recentTrips] = listCase.text
  }

  const {settings} = settingsOver(new MemoryStorage(entries))
  deepStrictEqual(settings.listRecentTrips(RECENT_COUNT_MAX), listCase.trips, `recent trips list: ${listCase.name}`)
}

{
  const storage = new MemoryStorage({[StorageKey.recentTrips]: JSON.stringify([tripA, tripB, tripC])})
  const {settings} = settingsOver(storage)
  deepStrictEqual(settings.addRecentTrip({trip: tripB, countMax: RECENT_COUNT_MAX}), [tripB, tripA, tripC], "recent trips: a trip again moves to the front")
  const tripD = {from: locationEnd, to: stopEndA}
  deepStrictEqual(settings.addRecentTrip({trip: tripD, countMax: RECENT_COUNT_MAX}), [tripD, tripB, tripA], "recent trips: the oldest leaves past the limit")
  deepStrictEqual(JSON.parse(storage.entries()[StorageKey.recentTrips]), [tripD, tripB, tripA], "recent trips: stored")
  throws(() => settings.addRecentTrip({trip: {from: locationEnd, to: {kind: "none"}}, countMax: RECENT_COUNT_MAX}), AssertionError, "recent trips: a trip with no To asserts")
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
  const followed = settings.readLocationFollow()
  const enabled = settings.readOfflineSchedulesEnabled()
  const favorites = settings.listFavorites(COUNT_MAX)
  const isShown = settings.readShowDirection()
  const isDenied = settings.readMotionPermissionDenied()
  const isBasemapSaved = settings.readOfflineBasemapEnabled()
  settings.writeTheme(ThemeSetting.dark)
  settings.writeVehicleFilter(filter)
  settings.removeVehicleFilter()
  settings.writeLocationFollow(true)
  settings.writeOfflineSchedulesEnabled(false)
  settings.writeShowDirection(false)
  settings.writeMotionPermissionDenied()
  settings.writeOfflineBasemapEnabled(true)
  const added = settings.addFavorite({favorite: favoriteA, countMax: COUNT_MAX})
  const removed = settings.removeFavorite({stopId: favoriteA.stopId, countMax: COUNT_MAX})
  const recents = settings.listRecentTrips(COUNT_MAX)
  const recentAdded = settings.addRecentTrip({trip: tripA, countMax: COUNT_MAX})

  deepStrictEqual(recents, [], `${throwingCase.name}: recent trips`)
  deepStrictEqual(recentAdded, [tripA], `${throwingCase.name}: recent trip added`)
  deepStrictEqual(theme, ThemeSetting.system, `${throwingCase.name}: theme`)
  deepStrictEqual(read, {kind: FilterKind.none}, `${throwingCase.name}: filter`)
  deepStrictEqual(followed, false, `${throwingCase.name}: location button`)
  deepStrictEqual(enabled, true, `${throwingCase.name}: offline`)
  deepStrictEqual(favorites, [], `${throwingCase.name}: favorites`)
  deepStrictEqual(isShown, true, `${throwingCase.name}: direction setting`)
  deepStrictEqual(isDenied, false, `${throwingCase.name}: motion denial`)
  deepStrictEqual(isBasemapSaved, false, `${throwingCase.name}: offline basemap`)
  deepStrictEqual(added, {kind: FavoriteChangeKind.changed, favorites: [favoriteA]}, `${throwingCase.name}: add`)
  deepStrictEqual(removed, {kind: FavoriteChangeKind.unchanged}, `${throwingCase.name}: remove`)
  deepStrictEqual(warnings.length, THROWING_WARNING_COUNT, `${throwingCase.name}: warnings`)
}

// The theme script of the offline screen, run against a storage double, a
// document double whose one theme-color meta element records its content,
// and a system that prefers light or dark.
const scriptMatch = OFFLINE_SCREEN.match(/<script>([\s\S]*?)<\/script>/)
const offlineThemeScript = new Function("localStorage", "document", "matchMedia", scriptMatch[1])
const THEME_COLOR_SELECTOR = "meta[name=\"theme-color\"]"

class ThemeColorMeta {
  constructor() {
    this.attributes = {}
  }

  setAttribute(name, value) {
    this.attributes[name] = value
  }
}

function offlineScreenRun({storage, systemDark}) {
  const meta = new ThemeColorMeta()

  function querySelector(selector) {
    deepStrictEqual(selector, THEME_COLOR_SELECTOR, "offline screen: the element the script looks up")
    return meta
  }

  function matchMedia(query) {
    deepStrictEqual(query, "(prefers-color-scheme: dark)", "offline screen: the media query")
    return {matches: systemDark}
  }

  const document = {documentElement: {dataset: {}}, querySelector}
  offlineThemeScript(storage, document, matchMedia)
  return {theme: document.documentElement.dataset.theme, themeColor: meta.attributes.content}
}

function offlineScreenTheme(storage) {
  const run = offlineScreenRun({storage, systemDark: false})
  return run.theme
}

deepStrictEqual(
  OFFLINE_SCREEN.match(/<meta name="theme-color"[^>]*>/g),
  [`<meta name="theme-color" content="${themeColor(Theme.light)}">`],
  "offline screen: one theme-color meta element, light until the script runs"
)

for (const themeCase of themeCases) {
  for (const systemDark of [false, true]) {
    const storage = new MemoryStorage(themeCase.entries)
    const run = offlineScreenRun({storage, systemDark})
    const theme = resolveTheme({setting: themeCase.setting, systemDark})
    deepStrictEqual(run.themeColor, themeColor(theme), `offline screen theme color: ${themeCase.name}, system dark: ${systemDark}`)
  }
}

for (const systemDark of [false, true]) {
  const run = offlineScreenRun({storage: new ThrowingStorage(), systemDark})
  const theme = resolveTheme({setting: ThemeSetting.system, systemDark})
  deepStrictEqual(run.themeColor, themeColor(theme), `offline screen theme color: storage that throws, system dark: ${systemDark}`)
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
