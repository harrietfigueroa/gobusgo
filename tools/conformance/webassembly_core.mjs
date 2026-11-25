// The WebAssembly entry of the conformance cases: the Rust core through its
// web binding, built into priv/static/assets/core/.
// The binding's exports take the arguments of the JavaScript functions of the
// same names, so each module here only names them; a constant crosses as a
// function, since wasm-bindgen exports functions, and is read once here.

import initialize, * as binding from "../../priv/static/assets/core/gobusgo_core.js"

// The loader fetches the module from beside its own address, which the test
// server serves from the repository.
await initialize()

const AssertionError = binding.assertionErrorClass()

/** The modules the Rust core has ported, under the names the cases read. */
export const WEBASSEMBLY_CORE = Object.freeze({
  name: "webassembly",
  AssertionError,
  assert: Object.freeze({
    AssertionError,
    assertCondition: binding.assertCondition,
    unreachable: binding.unreachable
  }),
  checks: Object.freeze({
    assertFinite: binding.assertFinite,
    assertOrdered: binding.assertOrdered
  }),
  angles: Object.freeze({
    DEGREES_PER_TURN: binding.degreesPerTurn(),
    DEGREES_PER_HALF_TURN: binding.degreesPerHalfTurn(),
    radians: binding.radians,
    degrees: binding.degrees,
    normalizedDegrees: binding.normalizedDegrees,
    turnDegrees: binding.turnDegrees
  }),
  geodesy: Object.freeze({
    EARTH_RADIUS_METERS: binding.earthRadiusMeters(),
    METERS_PER_DEGREE: binding.metersPerDegree(),
    PLANE_SCALE_ERROR_MAX: binding.planeScaleErrorMax(),
    assertPosition: binding.assertPosition,
    distanceMeters: binding.distanceMeters,
    initialBearingDegrees: binding.initialBearingDegrees,
    metersPerDegreeLongitude: binding.metersPerDegreeLongitude,
    tangentPlane: binding.tangentPlane,
    assertPlaneCovers: binding.assertPlaneCovers
  }),
  interpolation: Object.freeze({
    lerp: binding.lerp,
    clamp: binding.clamp
  }),
  routingSnapshot: Object.freeze({
    FORMAT_VERSION: binding.routingSnapshotFormatVersion(),
    POSITION_UNKNOWN_MICRODEGREES: binding.positionUnknownMicrodegrees(),
    DecodeKind: binding.routingSnapshotDecodeKind(),
    RefusalReason: binding.routingSnapshotRefusalReason(),
    decodeStops: binding.decodeStops,
    decodeTrips: binding.decodeTrips,
    decodeTransfers: binding.decodeTransfers,
    decodeConnections: binding.decodeConnections,
    decodePositions: binding.decodePositions
  }),
  routingWalk: Object.freeze({
    WalkBasis: binding.routingWalkBasis(),
    WALK_CANDIDATE_COUNT_MAX: binding.walkCandidateCountMax(),
    walkBasisOf: binding.walkBasisOf,
    isStreetWalk: binding.isStreetWalk,
    streetMetersMaxOf: binding.streetMetersMaxOf,
    startsNear: binding.startsNear,
    walkCandidatesNear: binding.walkCandidatesNear,
    startsFromStreets: binding.startsFromStreets
  }),
  routingEngine: Object.freeze({
    ROUNDS_MAX: binding.routingEngineRoundsMax(),
    LegKind: binding.routingEngineLegKind(),
    OriginKind: binding.routingEngineOriginKind(),
    createEngine: binding.createEngine,
    route: binding.route,
    routeArrivingBy: binding.routeArrivingBy
  }),
  tripPath: Object.freeze({
    TRIP_PATH_COUNT_MAX: binding.tripPathCountMax(),
    decodeTripPath: binding.decodeTripPath,
    tripPathKey: binding.tripPathKey,
    tripPathOf: binding.tripPathOf
  })
})
