// Checks the list of the vehicles and stops in view of the vehicle map as
// pure functions of values written out by hand: which items it holds, in
// what order, the text of each option, and how the keys move the active
// option. Run it with `node test/scripts/map_items_check.mjs`; it exits
// non-zero on the first case that differs.

import {deepStrictEqual, throws} from "node:assert/strict"
import {itemsInView, itemKey, ListKey, MapItemKind, nextActiveIndex} from "../../assets/js/map_items.js"

const center = {x: 100, y: 100}
const COUNT_MAX = 3

const rapid = {id: "1_m1", route: "E Line", headsign: "Aurora Village", vehicleId: "1_7001", x: 110, y: 100}
const nameless = {id: "1_m2", route: undefined, headsign: undefined, vehicleId: "1_7002", x: 300, y: 100}
const routeOnly = {id: "1_m3", route: "36", headsign: undefined, vehicleId: "1_7003", x: 100, y: 160}
const scheduled = {id: "s_m4", route: "E Line", headsign: undefined, vehicleId: undefined, x: 100, y: 400}
const pine = {id: "1_431", name: "Pine St & 3rd Ave", direction: "W", routes: "E Line, 36", x: 100, y: 105}
const unnamed = {id: "1_999", name: undefined, direction: undefined, routes: "", x: 500, y: 500}
// As far from the middle as `rapid`, on the other side.
const tied = {id: "1_432", name: "3rd Ave & Pike St", direction: "S", routes: "C Line", x: 90, y: 100}

const VEHICLE_TEXT = "Vehicle, E Line to Aurora Village"
const PINE_TEXT = "Stop, Pine St & 3rd Ave, W, routes E Line, 36"
const TIED_TEXT = "Stop, 3rd Ave & Pike St, S, routes C Line"
const ROUTE_ONLY_TEXT = "Vehicle, 36"

function item({kind, id, text}) {
  return {kind, id, text}
}

const listCases = [
  {name: "nothing in view", view: {vehicles: [], stops: []}, expected: {items: [], restCount: 0}},
  {
    name: "nearest the middle first",
    view: {vehicles: [rapid, routeOnly], stops: [pine]},
    expected: {
      items: [
        item({kind: MapItemKind.stop, id: pine.id, text: PINE_TEXT}),
        item({kind: MapItemKind.vehicle, id: rapid.id, text: VEHICLE_TEXT}),
        item({kind: MapItemKind.vehicle, id: routeOnly.id, text: ROUTE_ONLY_TEXT})
      ],
      restCount: 0
    }
  },
  {
    name: "a vehicle before a stop as near",
    view: {vehicles: [rapid], stops: [tied]},
    expected: {
      items: [
        item({kind: MapItemKind.vehicle, id: rapid.id, text: VEHICLE_TEXT}),
        item({kind: MapItemKind.stop, id: tied.id, text: TIED_TEXT})
      ],
      restCount: 0
    }
  },
  {
    name: "the nearest items up to the count, and the count of the rest",
    view: {vehicles: [nameless, rapid, routeOnly, scheduled], stops: [pine, unnamed]},
    expected: {
      items: [
        item({kind: MapItemKind.stop, id: pine.id, text: PINE_TEXT}),
        item({kind: MapItemKind.vehicle, id: rapid.id, text: VEHICLE_TEXT}),
        item({kind: MapItemKind.vehicle, id: routeOnly.id, text: ROUTE_ONLY_TEXT})
      ],
      restCount: 3
    }
  }
]

for (const {name, view, expected} of listCases) {
  deepStrictEqual(itemsInView({...view, center, countMax: COUNT_MAX}), expected, name)
}

const textCases = [
  {name: "a vehicle with no route or headsign", view: {vehicles: [nameless], stops: []}, expected: "Vehicle 1_7002"},
  {name: "a scheduled trip with a route", view: {vehicles: [scheduled], stops: []}, expected: "Vehicle, E Line"},
  {name: "a stop with no name", view: {vehicles: [], stops: [unnamed]}, expected: "Stop 1_999"}
]

for (const {name, view, expected} of textCases) {
  const {items} = itemsInView({...view, center, countMax: COUNT_MAX})
  deepStrictEqual(items[0].text, expected, name)
}

const zeroCount = {vehicles: [], stops: [], center, countMax: 0}

function zeroCountList() {
  return itemsInView(zeroCount)
}

throws(zeroCountList, "a list with room for no item")

deepStrictEqual(itemKey({kind: MapItemKind.stop, id: "1_431"}), "stop:1_431", "an item's key")

const LAST_INDEX = 4
const COUNT = 5

const keyCases = [
  {name: "down from the first", key: ListKey.down, activeIndex: 0, expected: 1},
  {name: "down from the last stays", key: ListKey.down, activeIndex: LAST_INDEX, expected: LAST_INDEX},
  {name: "up from the first stays", key: ListKey.up, activeIndex: 0, expected: 0},
  {name: "up from the second", key: ListKey.up, activeIndex: 1, expected: 0},
  {name: "home", key: ListKey.home, activeIndex: LAST_INDEX, expected: 0},
  {name: "end", key: ListKey.end, activeIndex: 0, expected: LAST_INDEX}
]

for (const {name, key, activeIndex, expected} of keyCases) {
  deepStrictEqual(nextActiveIndex({key, activeIndex, count: COUNT}), expected, name)
}

const emptyMove = {key: ListKey.down, activeIndex: 0, count: 0}

function emptyListMove() {
  return nextActiveIndex(emptyMove)
}

throws(emptyListMove, "a move in an empty list")

const caseCount = listCases.length + textCases.length + keyCases.length
console.log(`map items check passed: ${caseCount} cases`)
