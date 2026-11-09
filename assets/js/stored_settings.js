// The rider's settings and favorites this browser keeps, and the one module
// that reads and writes them. Every key lives in local storage as text, and
// every read is synchronous, so the stored filter is offered before the map
// asks for markers and the favorites are read on each popup placement.
// The key names, the schema version, and the stored themes come from the
// imported contract data, a JSON file that code outside the bundle can read
// as well. Nothing here reads the document; storage is the one dependency,
// and it is passed in.
//
// The contract, which a native app reimplements in its own store:
//
// - `gobusgo:theme`: the rider's theme, the text "light" or "dark". No key
//   is Match system, the default, and any other text reads as Match system.
//   Losing it draws the page in the system's theme.
// - `gobusgo:favorite-stops`: the rider's favorite stops as a JSON list in
//   the rider's order, at most the six of
//   `GobusgoWeb.VehicleLive.OpenStops.favorite_count_max/0`, for example
//   `[{"stopId":"1_100","name":"Pine St & 3rd Ave"}]`. A new favorite is
//   added at the end, and a move puts one favorite at another index; the
//   first entry is the one the rider puts first. An entry needs a
//   non-empty string `stopId` and a string `name`; an entry of another
//   shape, a stop listed again, and the entries past the limit are left out.
//   No key, text that is not JSON, and a value that is not a list read as
//   no favorite. Losing it loses every favorite, the one value the rider
//   wrote by hand.
// - `gobusgo:vehicle-filter`: the vehicle page's last accepted filter as
//   JSON, for example `{"agency":["1"],"route":["1_100479"]}`. Any JSON
//   value but null is offered to the page, which judges it again and has a
//   refused one removed. No key, null, and text that is not JSON read as no
//   filter. Losing it shows every vehicle.
// - `gobusgo:snap-to-location`: the text "true" while the rider left the
//   location button on, Following or Located, never a position; turning
//   the button off removes the key. Any other text, and no key, read as
//   off. Losing it ends the follow on load.
// - `gobusgo:offline-schedules`: the text "off" while the rider keeps
//   saving schedules for offline use turned off. No key is on, the default,
//   and any other text reads as on. Losing it turns saving back on.
// - `gobusgo:offline-basemap`: the text "on" while the rider keeps saving
//   the map for offline use turned on. No key is off, the default, and any
//   other text reads as off. Losing it stops saving the map, and the next
//   page removes the saved copy.
// - `gobusgo:shared-vehicles`: the text "on" while the rider keeps the shared
//   scooter and bike layer on. No key is off, the default, and any other
//   text reads as off. Losing it turns the layer off.
// - `gobusgo:show-direction`: the text "off" while the rider keeps Show my
//   direction turned off, never a heading. No key is on, the default, and
//   any other text reads as on. Losing it draws the cone on the dot again.
// - `gobusgo:motion-permission`: the text "denied" once the browser's
//   motion permission prompt was answered with a denial, so the page never
//   asks again. Any other text, and no key, read as never denied. Losing it
//   asks once more on the next click that starts following.
// - `gobusgo:stored-settings-version`: the schema version of the keys
//   above, as decimal text, now "1". A key added whose absence reads as its
//   default, as the last four are, leaves version 1's stored values as they
//   are and needs no migration, so it keeps the version.
//
// The migration rule: on its first use in a page, the module reads the
// version, runs the migration from each earlier version to the next in
// order, and stores the current version. No version key is version 0, the
// keys stored before this module existed, whose shapes are version 1's, so
// its migration is the identity; text that is not a version reads as 0. A
// version later than this module's, stored by a later release, is left as
// it is, and each value is read with the checks above.
//
// Storage that throws, as in a private window, reads as each key's default
// and writes nothing, and every call that throws is logged through `warn`.

import contract from "./stored_settings.json" with {type: "json"}
import {assertCondition} from "./assert.js"
import {Theme, ThemeSetting, parseSetting} from "./theme.js"

/** The schema version of the stored keys. */
export const SCHEMA_VERSION = contract.schemaVersion

/** The local storage key of each stored value. */
export const StorageKey = Object.freeze({...contract.keys})

/** The texts of `gobusgo:theme` that name a theme; anything else is Match system. */
export const STORED_THEMES = Object.freeze([...contract.storedThemes])

/** The kinds of a read of the stored vehicle filter. */
export const FilterKind = Object.freeze({found: "found", none: "none"})

/** The kinds of the outcome of adding, removing, or moving a favorite. */
export const FavoriteChangeKind = Object.freeze({changed: "changed", unchanged: "unchanged"})

const LOCATION_FOLLOW_STORED = "true"
const OFFLINE_SCHEDULES_OFF = "off"
const OFFLINE_BASEMAP_ON = "on"
const SHOW_DIRECTION_OFF = "off"
const MOTION_PERMISSION_DENIED = "denied"
const SHARED_VEHICLES_SHOWN = "on"
const UNVERSIONED = 0

// The kinds of a stored entry read back as a favorite.
const EntryKind = Object.freeze({favorite: "favorite", malformed: "malformed"})

const themes = Object.values(Theme)
assertCondition(Number.isSafeInteger(SCHEMA_VERSION), "the schema version must be an integer, got: " + String(SCHEMA_VERSION))
const isEveryStoredTheme = STORED_THEMES.every(isTheme)
assertCondition(isEveryStoredTheme, "every stored theme must be a theme, got: " + STORED_THEMES.join(", "))

// The migration from each version to the next, at the index of the version
// it starts from. Each takes and returns the stored text of every key.
const migrations = Object.freeze([migrateUnversioned])
assertCondition(migrations.length === SCHEMA_VERSION, `there must be one migration per version, got ${migrations.length} for version ${SCHEMA_VERSION}`)

function isTheme(value) {
  return themes.includes(value)
}

function migrateUnversioned(values) {
  return values
}

/**
 * The stored text of every key, `values`, keyed by key, as version
 * `version` holds it, migrated to the current version. A version later
 * than the current one is returned as it is.
 */
export function migrateValues({version, values}) {
  assertCondition(Number.isSafeInteger(version), "version must be an integer, got: " + String(version))
  assertCondition(version >= UNVERSIONED, "version must not be negative, got: " + String(version))
  let migrated = values

  for (let index = version; index < migrations.length; index += 1) {
    migrated = migrations[index](migrated)
  }

  return migrated
}

/**
 * The stored settings over the storage `storage` returns, a function so
 * that a browser which throws on reaching local storage throws inside the
 * fallback. `warn` receives a description and the error of every storage
 * call that throws, and is the one place a failure is logged.
 */
export function openStoredSettings({storage, warn}) {
  let isMigrated = false

  // Runs `operation` on the storage, after the migration on first use, and
  // returns `fallback` when storage or the parse of what it holds throws.
  function guarded({description, fallback, operation}) {
    migrateOnce()

    try {
      const reached = storage()
      return operation(reached)
    } catch (error) {
      warn(description, error)
      return fallback
    }
  }

  // The migration runs at most once per page, so storage that throws warns
  // of it once.
  function migrateOnce() {
    if (isMigrated) {
      return
    }

    isMigrated = true

    try {
      const reached = storage()
      migrateStorage(reached)
    } catch (error) {
      warn("Stored settings not migrated", error)
    }
  }

  function listFavorites(countMax) {
    return guarded({
      description: "Stored favorite stops not readable",
      fallback: [],
      operation: (reached) => listFavoritesFrom({reached, countMax})
    })
  }

  // Stores the favorites of `change` when it changed them, and returns it.
  function storeChange(change) {
    if (change.kind === FavoriteChangeKind.changed) {
      guarded({
        description: "Favorite stops not stored",
        fallback: undefined,
        operation: (reached) => { writeFavoritesTo({reached, favorites: change.favorites}) }
      })
    }

    return change
  }

  return Object.freeze({
    /** The rider's theme setting, Match system when none is stored. */
    readTheme() {
      return guarded({description: "Theme setting not readable", fallback: ThemeSetting.system, operation: readThemeFrom})
    },

    /** Stores the theme setting `setting`; Match system is stored as no key. */
    writeTheme(setting) {
      guarded({
        description: "Theme setting not stored",
        fallback: undefined,
        operation: (reached) => { writeThemeTo({reached, setting}) }
      })
    },

    /** The stored vehicle filter, as a `FilterKind` member. */
    readVehicleFilter() {
      return guarded({description: "Stored vehicle filter not readable", fallback: {kind: FilterKind.none}, operation: readVehicleFilterFrom})
    },

    /** Stores the vehicle filter `filter`, a value JSON encodes. */
    writeVehicleFilter(filter) {
      guarded({
        description: "Vehicle filter not stored",
        fallback: undefined,
        operation: (reached) => { writeVehicleFilterTo({reached, filter}) }
      })
    },

    /** Removes the stored vehicle filter. */
    removeVehicleFilter() {
      guarded({description: "Stored vehicle filter not removed", fallback: undefined, operation: removeVehicleFilterFrom})
    },

    /** Whether the rider left the location button on, in Following or Located. */
    readLocationFollow() {
      return guarded({description: "Stored location button not readable", fallback: false, operation: readLocationFollowFrom})
    },

    /** Stores whether the rider left the location button on; off is stored as no key. */
    writeLocationFollow(isOn) {
      guarded({
        description: "Location button not stored",
        fallback: undefined,
        operation: (reached) => { writeLocationFollowTo({reached, isOn}) }
      })
    },

    /** Whether saving schedules for offline use is on, the default. */
    readOfflineSchedulesEnabled() {
      return guarded({description: "Offline schedules setting not readable", fallback: true, operation: readOfflineSchedulesEnabledFrom})
    },

    /** Stores whether saving schedules for offline use is on; on is stored as no key. */
    writeOfflineSchedulesEnabled(enabled) {
      guarded({
        description: "Offline schedules setting not stored",
        fallback: undefined,
        operation: (reached) => { writeOfflineSchedulesEnabledTo({reached, enabled}) }
      })
    },

    /** Whether saving the map for offline use is on; off is the default. */
    readOfflineBasemapEnabled() {
      return guarded({description: "Offline basemap setting not readable", fallback: false, operation: readOfflineBasemapEnabledFrom})
    },

    /** Stores whether saving the map for offline use is on; off is stored as no key. */
    writeOfflineBasemapEnabled(enabled) {
      guarded({
        description: "Offline basemap setting not stored",
        fallback: undefined,
        operation: (reached) => { writeOfflineBasemapEnabledTo({reached, enabled}) }
      })
    },

    /** Whether Show my direction is on, the default. */
    readShowDirection() {
      return guarded({description: "Direction setting not readable", fallback: true, operation: readShowDirectionFrom})
    },

    /** Stores whether Show my direction is on; on is stored as no key. */
    writeShowDirection(isShown) {
      guarded({
        description: "Direction setting not stored",
        fallback: undefined,
        operation: (reached) => { writeShowDirectionTo({reached, isShown}) }
      })
    },

    /** Whether the browser's motion permission prompt was answered with a denial. */
    readMotionPermissionDenied() {
      return guarded({description: "Motion permission denial not readable", fallback: false, operation: readMotionPermissionDeniedFrom})
    },

    /** Stores that the motion permission prompt was answered with a denial. */
    writeMotionPermissionDenied() {
      guarded({description: "Motion permission denial not stored", fallback: undefined, operation: writeMotionPermissionDeniedTo})
    },

    /** Whether the rider keeps the shared scooter and bike layer on; off is the default. */
    readSharedVehiclesShown() {
      return guarded({description: "Shared vehicles setting not readable", fallback: false, operation: readSharedVehiclesShownFrom})
    },

    /** Stores whether the shared scooter and bike layer is on; off is stored as no key. */
    writeSharedVehiclesShown(shown) {
      guarded({
        description: "Shared vehicles setting not stored",
        fallback: undefined,
        operation: (reached) => { writeSharedVehiclesShownTo({reached, shown}) }
      })
    },

    /** The stored favorites, each once, at most `countMax` of them. */
    listFavorites,

    /**
     * Adds `favorite`, a stop's `stopId` and `name`, after the other
     * favorites, as a `FavoriteChangeKind` member. A stop that is a favorite
     * already, and a favorite past `countMax`, leave the favorites unchanged.
     */
    addFavorite({favorite, countMax}) {
      const favorites = listFavorites(countMax)
      const change = favoritesAdded({favorites, favorite, countMax})
      return storeChange(change)
    },

    /**
     * Removes the favorite of the stop `stopId`, of at most `countMax`
     * favorites, as a `FavoriteChangeKind` member.
     */
    removeFavorite({stopId, countMax}) {
      const favorites = listFavorites(countMax)
      const change = favoritesRemoved({favorites, stopId})
      return storeChange(change)
    },

    /**
     * Moves the favorite of the stop `stopId`, of at most `countMax`
     * favorites, to `index` among them, as a `FavoriteChangeKind` member;
     * an index past the end moves it to the end. A stop that is no
     * favorite, and a move to where it stands, leave the favorites
     * unchanged.
     */
    moveFavorite({stopId, index, countMax}) {
      assertCondition(Number.isSafeInteger(index), "a favorite's index must be an integer, got: " + String(index))
      assertCondition(index >= 0, "a favorite's index must not be negative, got: " + String(index))
      const favorites = listFavorites(countMax)
      const change = favoritesMoved({favorites, stopId, index})
      return storeChange(change)
    }
  })
}

function browserStorage() {
  return window.localStorage
}

function warnInConsole(description, error) {
  console.warn(description, error)
}

/** The stored settings of this browser's local storage. */
export const storedSettings = openStoredSettings({storage: browserStorage, warn: warnInConsole})

// The operations over a reached storage. Each runs inside the fallback of
// `openStoredSettings`, so a call that throws reads as the key's default.

function readThemeFrom(reached) {
  const text = reached.getItem(StorageKey.theme)
  return parseSetting(text)
}

function writeThemeTo({reached, setting}) {
  if (setting === ThemeSetting.system) {
    reached.removeItem(StorageKey.theme)
  } else {
    reached.setItem(StorageKey.theme, setting)
  }
}

function readVehicleFilterFrom(reached) {
  const text = reached.getItem(StorageKey.vehicleFilter)
  return filterOf(text)
}

function writeVehicleFilterTo({reached, filter}) {
  const text = JSON.stringify(filter)
  reached.setItem(StorageKey.vehicleFilter, text)
}

function removeVehicleFilterFrom(reached) {
  reached.removeItem(StorageKey.vehicleFilter)
}

function readLocationFollowFrom(reached) {
  return reached.getItem(StorageKey.locationFollow) === LOCATION_FOLLOW_STORED
}

function writeLocationFollowTo({reached, isOn}) {
  if (isOn) {
    reached.setItem(StorageKey.locationFollow, LOCATION_FOLLOW_STORED)
  } else {
    reached.removeItem(StorageKey.locationFollow)
  }
}

function readOfflineSchedulesEnabledFrom(reached) {
  return reached.getItem(StorageKey.offlineSchedules) !== OFFLINE_SCHEDULES_OFF
}

function writeOfflineSchedulesEnabledTo({reached, enabled}) {
  if (enabled) {
    reached.removeItem(StorageKey.offlineSchedules)
  } else {
    reached.setItem(StorageKey.offlineSchedules, OFFLINE_SCHEDULES_OFF)
  }
}

function readOfflineBasemapEnabledFrom(reached) {
  return reached.getItem(StorageKey.offlineBasemap) === OFFLINE_BASEMAP_ON
}

function writeOfflineBasemapEnabledTo({reached, enabled}) {
  if (enabled) {
    reached.setItem(StorageKey.offlineBasemap, OFFLINE_BASEMAP_ON)
  } else {
    reached.removeItem(StorageKey.offlineBasemap)
  }
}

function readShowDirectionFrom(reached) {
  return reached.getItem(StorageKey.showDirection) !== SHOW_DIRECTION_OFF
}

function writeShowDirectionTo({reached, isShown}) {
  if (isShown) {
    reached.removeItem(StorageKey.showDirection)
  } else {
    reached.setItem(StorageKey.showDirection, SHOW_DIRECTION_OFF)
  }
}

function readMotionPermissionDeniedFrom(reached) {
  return reached.getItem(StorageKey.motionPermission) === MOTION_PERMISSION_DENIED
}

function writeMotionPermissionDeniedTo(reached) {
  reached.setItem(StorageKey.motionPermission, MOTION_PERMISSION_DENIED)
}

function readSharedVehiclesShownFrom(reached) {
  return reached.getItem(StorageKey.sharedVehicles) === SHARED_VEHICLES_SHOWN
}

function writeSharedVehiclesShownTo({reached, shown}) {
  if (shown) {
    reached.setItem(StorageKey.sharedVehicles, SHARED_VEHICLES_SHOWN)
  } else {
    reached.removeItem(StorageKey.sharedVehicles)
  }
}

function listFavoritesFrom({reached, countMax}) {
  const text = reached.getItem(StorageKey.favoriteStops)
  return favoritesTextOf({text, countMax})
}

function writeFavoritesTo({reached, favorites}) {
  const text = JSON.stringify(favorites)
  reached.setItem(StorageKey.favoriteStops, text)
}

function migrateStorage(reached) {
  const versionText = reached.getItem(StorageKey.schemaVersion)
  const version = versionOf(versionText)

  if (version >= SCHEMA_VERSION) {
    return
  }

  const values = storedValues(reached)
  const migrated = migrateValues({version, values})
  writeChangedValues({reached, values, migrated})
  reached.setItem(StorageKey.schemaVersion, String(SCHEMA_VERSION))
}

function storedValues(reached) {
  const values = {}

  for (const key of Object.values(StorageKey)) {
    values[key] = reached.getItem(key)
  }

  return values
}

function writeChangedValues({reached, values, migrated}) {
  for (const key of Object.values(StorageKey)) {
    const isChanged = migrated[key] !== values[key]
    const isRemoved = isChanged && migrated[key] === null

    if (isRemoved) {
      reached.removeItem(key)
    } else if (isChanged) {
      reached.setItem(key, migrated[key])
    }
  }
}

function versionOf(text) {
  const isVersionText = text !== null && /^\d+$/.test(text)
  const version = Number(text)
  const isVersion = isVersionText && Number.isSafeInteger(version)

  if (isVersion) {
    return version
  } else {
    return UNVERSIONED
  }
}

function filterOf(text) {
  if (text === null) {
    return {kind: FilterKind.none}
  }

  const filter = JSON.parse(text)

  if (filter === null) {
    return {kind: FilterKind.none}
  } else {
    return {kind: FilterKind.found, filter}
  }
}

function favoritesTextOf({text, countMax}) {
  if (text === null) {
    return []
  }

  const value = JSON.parse(text)
  return favoritesOf({value, countMax})
}

function favoritesOf({value, countMax}) {
  const favorites = []

  if (Array.isArray(value) === false) {
    return favorites
  }

  for (const entry of value.slice(0, countMax)) {
    const read = favoriteOf(entry)

    if (read.kind === EntryKind.favorite) {
      const isNew = favorites.every((kept) => kept.stopId !== read.favorite.stopId)

      if (isNew) {
        favorites.push(read.favorite)
      }
    }
  }

  return favorites
}

function favoriteOf(value) {
  const isObject = typeof value === "object" && value !== null
  const hasStopIdText = isObject && typeof value.stopId === "string"
  const hasStopId = hasStopIdText && value.stopId !== ""
  const isFavorite = hasStopId && typeof value.name === "string"

  if (isFavorite) {
    return {kind: EntryKind.favorite, favorite: {stopId: value.stopId, name: value.name}}
  } else {
    return {kind: EntryKind.malformed}
  }
}

// The favorites `favorites` with `favorite` after them, or unchanged for a
// stop that is a favorite already and for favorites that hold `countMax`.
function favoritesAdded({favorites, favorite, countMax}) {
  const isNew = favorites.every((kept) => kept.stopId !== favorite.stopId)
  const hasRoom = favorites.length < countMax
  const isAddable = isNew && hasRoom

  if (isAddable) {
    const changed = [...favorites, {stopId: favorite.stopId, name: favorite.name}]
    return {kind: FavoriteChangeKind.changed, favorites: changed}
  } else {
    return {kind: FavoriteChangeKind.unchanged}
  }
}

function favoritesRemoved({favorites, stopId}) {
  const kept = favorites.filter((favorite) => favorite.stopId !== stopId)

  if (kept.length < favorites.length) {
    return {kind: FavoriteChangeKind.changed, favorites: kept}
  } else {
    return {kind: FavoriteChangeKind.unchanged}
  }
}

// The favorites `favorites` with that of `stopId` at `index`, the end for
// an index past it, or unchanged for a stop that is no favorite and for a
// favorite that stands at `index` already.
function favoritesMoved({favorites, stopId, index}) {
  const fromIndex = favorites.findIndex((favorite) => favorite.stopId === stopId)
  const isFavorite = fromIndex >= 0
  const lastIndex = favorites.length - 1
  const toIndex = Math.min(index, lastIndex)
  const isMoved = isFavorite && toIndex !== fromIndex

  if (isMoved) {
    const others = favorites.filter((favorite) => favorite.stopId !== stopId)
    const moved = favorites[fromIndex]
    const changed = [...others.slice(0, toIndex), moved, ...others.slice(toIndex)]
    return {kind: FavoriteChangeKind.changed, favorites: changed}
  } else {
    return {kind: FavoriteChangeKind.unchanged}
  }
}
