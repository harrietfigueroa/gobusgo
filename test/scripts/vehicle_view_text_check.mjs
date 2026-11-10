// Checks the texts of a vehicle's details view as labels, as pure functions
// of values written out by hand: the title, the muted line under it, the
// key-value rows, and the note on the position, for a live vehicle whose
// marker is an estimate or stands at its last report, a stale one, a
// schedule-only one where the source puts it, and a saved schedule's trip,
// with texts missing. Run it
// with `node test/scripts/vehicle_view_text_check.mjs`; it exits non-zero on
// the first case that differs.

import {deepStrictEqual} from "node:assert/strict"
import {MarkerPositionKind} from "../../assets/js/vehicle_motion.js"
import {shortStatusLabel, vehicleViewText} from "../../assets/js/vehicle_view_text.js"

const ESTIMATED_NOTE = "The marker is an estimate: it moves along the route at the schedule's pace from the last report, which the ring marks."
const LAST_REPORT_NOTE = "The marker stands at the last report."
const FETCHED_NOTE = "The marker stands where the source estimates the vehicle is."

deepStrictEqual(shortStatusLabel("Stale · over 2 min"), "Stale", "a label's first part is its short form")
deepStrictEqual(shortStatusLabel("Live"), "Live", "a label of one part is its own short form")

const live = {
  route: "E Line",
  headsign: "Aurora Village TC",
  vehicleId: "1_7012",
  statusLabel: "Live",
  locationAge: "42 s ago",
  schedule: "2 min late",
  nextStop: "3rd Ave & Pike St · 1 min",
  isScheduledTrip: false,
  position: MarkerPositionKind.estimated
}

const cases = [
  {
    case: "a live bus with every text",
    given: live,
    text: {
      title: "E Line",
      meta: "To Aurora Village TC · bus 7012",
      rows: [
        {key: "Status", value: "Live"},
        {key: "Last reported", value: "42 s ago"},
        {key: "Position", value: "Estimated"},
        {key: "Schedule", value: "2 min late"},
        {key: "Next stop", value: "3rd Ave & Pike St · 1 min"}
      ],
      note: ESTIMATED_NOTE
    }
  },
  {
    case: "a live bus whose path the page lacks",
    given: {...live, position: MarkerPositionKind.lastReport},
    text: {
      title: "E Line",
      meta: "To Aurora Village TC · bus 7012",
      rows: [
        {key: "Status", value: "Live"},
        {key: "Last reported", value: "42 s ago"},
        {key: "Position", value: "At last report"},
        {key: "Schedule", value: "2 min late"},
        {key: "Next stop", value: "3rd Ave & Pike St · 1 min"}
      ],
      note: LAST_REPORT_NOTE
    }
  },
  {
    case: "a stale bus, with no lateness or next stop",
    given: {...live, statusLabel: "Stale · over 2 min", locationAge: "3 min 10 s ago", schedule: null, nextStop: null, position: MarkerPositionKind.lastReport},
    text: {
      title: "E Line",
      meta: "To Aurora Village TC · bus 7012",
      rows: [
        {key: "Status", value: "Stale"},
        {key: "Last reported", value: "3 min 10 s ago"},
        {key: "Position", value: "At last report"}
      ],
      note: LAST_REPORT_NOTE
    }
  },
  {
    case: "a bus that has never reported",
    given: {...live, statusLabel: "Schedule only", locationAge: "No location reported", schedule: null, position: MarkerPositionKind.fetched},
    text: {
      title: "E Line",
      meta: "To Aurora Village TC · bus 7012",
      rows: [
        {key: "Status", value: "Schedule only"},
        {key: "Position", value: "Source's estimate"},
        {key: "Next stop", value: "3rd Ave & Pike St · 1 min"}
      ],
      note: FETCHED_NOTE
    }
  },
  {
    case: "a bus with no route",
    given: {...live, route: null},
    text: {
      title: "Aurora Village TC",
      meta: "bus 7012",
      rows: [
        {key: "Status", value: "Live"},
        {key: "Last reported", value: "42 s ago"},
        {key: "Position", value: "Estimated"},
        {key: "Schedule", value: "2 min late"},
        {key: "Next stop", value: "3rd Ave & Pike St · 1 min"}
      ],
      note: ESTIMATED_NOTE
    }
  },
  {
    case: "a bus with neither route nor headsign",
    given: {...live, route: null, headsign: null},
    text: {
      title: "Bus 7012",
      meta: "",
      rows: [
        {key: "Status", value: "Live"},
        {key: "Last reported", value: "42 s ago"},
        {key: "Position", value: "Estimated"},
        {key: "Schedule", value: "2 min late"},
        {key: "Next stop", value: "3rd Ave & Pike St · 1 min"}
      ],
      note: ESTIMATED_NOTE
    }
  },
  {
    case: "a saved schedule's trip",
    given: {...live, vehicleId: null, statusLabel: "Schedule only", locationAge: "Not supplied", schedule: null, isScheduledTrip: true, position: MarkerPositionKind.fetched},
    text: {
      title: "E Line",
      meta: "To Aurora Village TC · scheduled trip",
      rows: [
        {key: "Status", value: "Schedule only"},
        {key: "Next stop", value: "3rd Ave & Pike St · 1 min"}
      ],
      note: "Position is the saved schedule's; delays, cancellations, and detours are unknown."
    }
  }
]

for (const {case: caseName, given, text} of cases) {
  deepStrictEqual(vehicleViewText(given), text, caseName)
}

const SHORT_LABEL_CASE_COUNT = 2
console.log(`vehicle view texts: ${cases.length + SHORT_LABEL_CASE_COUNT} cases hold`)
