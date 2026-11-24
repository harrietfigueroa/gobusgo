//! The core's binding for the web. Each export converts its arguments and result
//! across wasm-bindgen and holds no logic of its own. An export takes the
//! arguments the JavaScript module of the same name takes, an options object
//! read through its properties where that module takes one, so a stand-in for
//! the module renames nothing.
//!
//! Every argument crosses as a `JsValue` and is read inside the call: a number
//! must be one, where wasm-bindgen's conversion would coerce a string or `null`
//! to a number, and text is read with `String`, so `undefined` reads as
//! `undefined`, as the JavaScript writes it. A failed assertion of the core, and
//! any exception JavaScript throws while the binding reads an argument, throws
//! this module's `AssertionError`, which `assertionErrorClass` returns.

use gobusgo_core::assert::{self, AssertionError as CoreAssertionError, number_text};
use gobusgo_core::math::{angles, checks, geodesy, interpolation};
use gobusgo_core::{packed_container, routing_snapshot, routing_walk, trip_path};
use wasm_bindgen::prelude::{JsValue, wasm_bindgen};

// The length of an array that holds a position's two coordinates.
const COORDINATE_COUNT: f64 = 2.0;

/// The version of the core this module was built from.
#[wasm_bindgen(js_name = coreVersion)]
#[must_use]
pub fn core_version() -> String {
    gobusgo_core::core_version().to_owned()
}

// The failure every assertion throws; the objects a result crosses as, which
// JavaScript builds from copies so that no value a caller holds points into the
// module's memory; and a property read as JavaScript reads `target[key]`.
//
// Every function here is imported with `catch` and called through `caught`, so
// a throw of JavaScript's becomes the core's assertion failure and its panic
// hook renews the instance: an exception unwinding through the module's frames
// otherwise skips the hook and leaves a slot of the table of JavaScript values
// taken, and once the table is full every export fails.
#[wasm_bindgen(inline_js = "
export class AssertionError extends Error {}
export function assertionError(message) { return new AssertionError(message) }
export function plane(referenceLatitudeDegrees, metersPerDegreeLon) {
  return Object.freeze({referenceLatitudeDegrees, metersPerDegreeLon})
}
export function property(target, key) { return target[key] }
function selfEntry(name) { return [name, name] }
export function names(list) { return Object.freeze(Object.fromEntries(Array.from(list, selfEntry))) }
export function typeName(value) { return Object.prototype.toString.call(value) }
export function bufferBytes(buffer) { return new Uint8Array(buffer) }
export function refusal(kind, reason) { return {kind, reason} }
export function decoded(kind, records) { return {kind, records} }
export function texts(text, ends) {
  const list = new Array(ends.length)
  let start = 0
  for (let index = 0; index < ends.length; index += 1) {
    list[index] = text.slice(start, ends[index])
    start = ends[index]
  }
  return list
}
export function trips(idText, idEnds, routeText, routeEnds, offsets) {
  const ids = texts(idText, idEnds)
  const routeIds = texts(routeText, routeEnds)
  const list = new Array(ids.length)
  for (let index = 0; index < ids.length; index += 1) {
    list[index] = {id: ids[index], routeId: routeIds[index], serviceDayOffset: offsets[index]}
  }
  return list
}
export function transfers(fromStop, toStop, durationS) { return {fromStop, toStop, durationS} }
export function connections(departureS, arrivalS, departureStop, arrivalStop, trip, sequence, boarding, alighting) {
  return {departureS, arrivalS, departureStop, arrivalStop, trip, sequence, boarding, alighting}
}
export function positions(latMicrodegrees, lonMicrodegrees) { return {latMicrodegrees, lonMicrodegrees} }
export function decodedTripPath(tripId, routeId, serviceDateMs, key, coordinates, stopValues) {
  const points = []
  for (let index = 0; index < coordinates.length; index += 2) {
    points.push(Object.freeze([coordinates[index], coordinates[index + 1]]))
  }
  const stops = []
  for (let index = 0; index < stopValues.length; index += 3) {
    stops.push(Object.freeze({distanceMeters: stopValues[index], arrivalSeconds: stopValues[index + 1], departureSeconds: stopValues[index + 2]}))
  }
  return checkedTripPath(tripId, routeId, serviceDateMs, key, points, stops)
}
export function checkedTripPath(tripId, routeId, serviceDateMs, key, points, stops) {
  return Object.freeze({tripId, routeId, serviceDateMs, key, points: Object.freeze(points), stops: Object.freeze(stops)})
}
function distanceOf(stop) { return stop.distanceMeters }
export function stopDistances(stops) { return Array.from(stops, distanceOf) }
export function int32s(column) { return column }
export function starts(stops, walkSeconds) {
  const list = new Array(stops.length)
  for (let index = 0; index < stops.length; index += 1) {
    list[index] = {stop: stops[index], walkS: walkSeconds[index]}
  }
  return list
}
export function candidates(stops, lats, lons) {
  const list = new Array(stops.length)
  for (let index = 0; index < stops.length; index += 1) {
    list[index] = {stop: stops[index], lat: lats[index], lon: lons[index]}
  }
  return list
}
export function reachedValues(stops) {
  const values = []
  for (const reached of stops) {
    values.push(reached.stop, reached.streetM)
  }
  return values
}
")]
extern "C" {
    #[wasm_bindgen(thread_local_v2, js_name = AssertionError)]
    static ASSERTION_ERROR_CLASS: JsValue;

    #[wasm_bindgen(catch, js_name = assertionError)]
    fn try_assertion_error(message: &str) -> Result<JsValue, JsValue>;

    #[wasm_bindgen(catch, js_name = plane)]
    fn try_plane(
        reference_latitude_degrees: f64,
        meters_per_degree_lon: f64,
    ) -> Result<JsValue, JsValue>;

    #[wasm_bindgen(catch, js_name = property)]
    fn try_property(target: &JsValue, key: &str) -> Result<JsValue, JsValue>;

    #[wasm_bindgen(catch, js_name = names)]
    fn try_names(list: Vec<String>) -> Result<JsValue, JsValue>;

    #[wasm_bindgen(catch, js_name = typeName)]
    fn try_type_name(value: &JsValue) -> Result<String, JsValue>;

    #[wasm_bindgen(catch, js_name = bufferBytes)]
    fn try_buffer_bytes(buffer: &JsValue) -> Result<Vec<u8>, JsValue>;

    #[wasm_bindgen(catch, js_name = refusal)]
    fn try_refusal(kind: &str, reason: &str) -> Result<JsValue, JsValue>;

    #[wasm_bindgen(catch, js_name = decoded)]
    fn try_decoded(kind: &str, records: JsValue) -> Result<JsValue, JsValue>;

    #[wasm_bindgen(catch, js_name = texts)]
    fn try_texts(text: &str, ends: Vec<u32>) -> Result<JsValue, JsValue>;

    #[wasm_bindgen(catch, js_name = trips)]
    fn try_trips(
        id_text: &str,
        id_ends: Vec<u32>,
        route_text: &str,
        route_ends: Vec<u32>,
        offsets: Vec<u8>,
    ) -> Result<JsValue, JsValue>;

    #[wasm_bindgen(catch, js_name = transfers)]
    fn try_transfers(
        from_stop: Vec<u32>,
        to_stop: Vec<u32>,
        duration_s: Vec<u32>,
    ) -> Result<JsValue, JsValue>;

    #[expect(
        clippy::too_many_arguments,
        reason = "a connections file has eight columns"
    )]
    #[wasm_bindgen(catch, js_name = connections)]
    fn try_connections(
        departure_s: Vec<i32>,
        arrival_s: Vec<i32>,
        departure_stop: Vec<u32>,
        arrival_stop: Vec<u32>,
        trip: Vec<u32>,
        sequence: Vec<u16>,
        boarding: Vec<u8>,
        alighting: Vec<u8>,
    ) -> Result<JsValue, JsValue>;

    #[wasm_bindgen(catch, js_name = positions)]
    fn try_positions(
        lat_microdegrees: Vec<i32>,
        lon_microdegrees: Vec<i32>,
    ) -> Result<JsValue, JsValue>;

    #[wasm_bindgen(catch, js_name = decodedTripPath)]
    fn try_decoded_trip_path(
        trip_id: &JsValue,
        route_id: &JsValue,
        service_date_ms: &JsValue,
        key: &str,
        coordinates: Vec<f64>,
        stop_values: Vec<f64>,
    ) -> Result<JsValue, JsValue>;

    #[wasm_bindgen(catch, js_name = checkedTripPath)]
    fn try_checked_trip_path(
        trip_id: &JsValue,
        route_id: &JsValue,
        service_date_ms: &JsValue,
        key: &str,
        points: &JsValue,
        stops: &JsValue,
    ) -> Result<JsValue, JsValue>;

    #[wasm_bindgen(catch, js_name = stopDistances)]
    fn try_stop_distances(stops: &JsValue) -> Result<Vec<JsValue>, JsValue>;

    #[wasm_bindgen(catch, js_name = int32s)]
    fn try_int32s(column: &JsValue) -> Result<Vec<i32>, JsValue>;

    #[wasm_bindgen(catch, js_name = starts)]
    fn try_starts(stops: Vec<f64>, walk_seconds: Vec<f64>) -> Result<JsValue, JsValue>;

    #[wasm_bindgen(catch, js_name = candidates)]
    fn try_candidates(stops: Vec<f64>, lats: Vec<f64>, lons: Vec<f64>) -> Result<JsValue, JsValue>;

    #[wasm_bindgen(catch, js_name = reachedValues)]
    fn try_reached_values(stops: &JsValue) -> Result<Vec<JsValue>, JsValue>;
}

// JavaScript's `String(value)`, which throws for a value whose conversion to
// text throws.
#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(catch, js_name = String)]
    fn try_js_string(value: &JsValue) -> Result<JsValue, JsValue>;
}

// A panic of the core throws the AssertionError with its message, and the
// instance is made anew before the next call: the throw leaves the panic
// unfinished, with the module's stack and its count of panics where the panic
// left them.
//
// An export takes no `&str`: the loader of wasm-bindgen 0.2.130 copies such an
// argument into the module's memory ahead of the call guard that makes the
// instance anew, so the first call after a failure would read the text from
// the new instance's memory, where it is not.
// https://docs.rs/crate/wasm-bindgen-cli-support/0.2.130/source/src/js/binding.rs
// (`maybe_wrap_export_call`, which wraps the call alone) — checked 2026-11-14
#[wasm_bindgen(start)]
fn start() {
    std::panic::set_hook(Box::new(throw_assertion_error));
}

fn throw_assertion_error(info: &std::panic::PanicHookInfo<'_>) {
    let message = match info.payload().downcast_ref::<CoreAssertionError>() {
        Some(failure) => failure.message().to_owned(),
        None => match info.payload_as_str() {
            Some(text) => text.to_owned(),
            None => format!("a panic with no message at {:?}", info.location()),
        },
    };
    // An error that cannot be built is thrown in its place, still with the
    // renewal scheduled.
    let error = match try_assertion_error(&message) {
        Ok(error) | Err(error) => error,
    };
    wasm_bindgen::handler::schedule_reinit();
    wasm_bindgen::throw_val(error);
}

/// The class of the error every failed assertion of this module throws.
#[wasm_bindgen(js_name = assertionErrorClass)]
#[must_use]
pub fn assertion_error_class() -> JsValue {
    ASSERTION_ERROR_CLASS.with(JsValue::clone)
}

/// `assert.js`'s `assertCondition`: throws unless `condition` is truthy.
#[wasm_bindgen(js_name = assertCondition)]
pub fn assert_condition(condition: &JsValue, message: &JsValue) {
    assert::condition(condition.is_truthy(), || text(message));
}

/// `assert.js`'s `unreachable`: throws naming `value` as `String(value)` writes it.
#[wasm_bindgen]
pub fn unreachable(value: &JsValue, message: &JsValue) {
    let value_text = text(value);
    assert::unreachable(&value_text, &text(message));
}

/// `math/checks.js`'s `assertFinite`.
#[wasm_bindgen(js_name = assertFinite)]
pub fn assert_finite(value: &JsValue, label: &JsValue) {
    let label = text(label);
    let finite = finite_number(value, &label);
    checks::assert_finite(finite, &label);
}

/// `math/checks.js`'s `assertOrdered`.
#[wasm_bindgen(js_name = assertOrdered)]
pub fn assert_ordered(options: &JsValue) {
    let label = text(&property(options, "label"));
    checks::assert_ordered(checks::Ordered {
        low: number_property(options, "low"),
        high: number_property(options, "high"),
        label: &label,
    });
}

/// `math/angles.js`'s `DEGREES_PER_TURN`.
#[wasm_bindgen(js_name = degreesPerTurn)]
#[must_use]
// wasm-bindgen exports no const fn.
#[expect(clippy::missing_const_for_fn)]
pub fn degrees_per_turn() -> f64 {
    angles::DEGREES_PER_TURN
}

/// `math/angles.js`'s `DEGREES_PER_HALF_TURN`.
#[wasm_bindgen(js_name = degreesPerHalfTurn)]
#[must_use]
// wasm-bindgen exports no const fn.
#[expect(clippy::missing_const_for_fn)]
pub fn degrees_per_half_turn() -> f64 {
    angles::DEGREES_PER_HALF_TURN
}

/// `math/angles.js`'s `radians`.
#[wasm_bindgen]
#[must_use]
pub fn radians(degrees: &JsValue) -> f64 {
    angles::radians(finite_number(degrees, "angles: degrees"))
}

/// `math/angles.js`'s `degrees`.
#[wasm_bindgen]
#[must_use]
pub fn degrees(radians: &JsValue) -> f64 {
    angles::degrees(finite_number(radians, "angles: radians"))
}

/// `math/angles.js`'s `normalizedDegrees`.
#[wasm_bindgen(js_name = normalizedDegrees)]
#[must_use]
pub fn normalized_degrees(degrees: &JsValue) -> f64 {
    angles::normalized_degrees(finite_number(degrees, "angles: degrees"))
}

/// `math/angles.js`'s `turnDegrees`.
#[wasm_bindgen(js_name = turnDegrees)]
#[must_use]
pub fn turn_degrees(options: &JsValue) -> f64 {
    angles::turn_degrees(angles::Turn {
        from: number_property(options, "from"),
        to: number_property(options, "to"),
    })
}

/// `math/geodesy.js`'s `EARTH_RADIUS_METERS`.
#[wasm_bindgen(js_name = earthRadiusMeters)]
#[must_use]
// wasm-bindgen exports no const fn.
#[expect(clippy::missing_const_for_fn)]
pub fn earth_radius_meters() -> f64 {
    geodesy::EARTH_RADIUS_METERS
}

/// `math/geodesy.js`'s `METERS_PER_DEGREE`.
#[wasm_bindgen(js_name = metersPerDegree)]
#[must_use]
// wasm-bindgen exports no const fn.
#[expect(clippy::missing_const_for_fn)]
pub fn meters_per_degree() -> f64 {
    geodesy::METERS_PER_DEGREE
}

/// `math/geodesy.js`'s `PLANE_SCALE_ERROR_MAX`.
#[wasm_bindgen(js_name = planeScaleErrorMax)]
#[must_use]
// wasm-bindgen exports no const fn.
#[expect(clippy::missing_const_for_fn)]
pub fn plane_scale_error_max() -> f64 {
    geodesy::PLANE_SCALE_ERROR_MAX
}

/// `math/geodesy.js`'s `assertPosition`: `position` must be an array of two
/// numbers, and those a position.
#[wasm_bindgen(js_name = assertPosition)]
pub fn assert_position(position: &JsValue, label: &JsValue) {
    let label = text(label);
    assert::condition(position.is_array(), || {
        format!("{label}: a position is [lon, lat]")
    });
    let length = number_property(position, "length");
    let is_pair = length.total_cmp(&COORDINATE_COUNT).is_eq();
    assert::condition(is_pair, || {
        geodesy::coordinate_count_message(&label, &number_text(length))
    });
    let lon = coordinate(position, geodesy::Axis::Longitude, &label);
    let lat = coordinate(position, geodesy::Axis::Latitude, &label);
    let _ = geodesy::assert_position(&[lon, lat], &label);
}

/// `math/geodesy.js`'s `distanceMeters`.
#[wasm_bindgen(js_name = distanceMeters)]
#[must_use]
pub fn distance_meters(source: &JsValue, target: &JsValue) -> f64 {
    geodesy::distance_meters(between(source, target))
}

/// `math/geodesy.js`'s `initialBearingDegrees`.
#[wasm_bindgen(js_name = initialBearingDegrees)]
#[must_use]
pub fn initial_bearing_degrees(source: &JsValue, target: &JsValue) -> f64 {
    geodesy::initial_bearing_degrees(between(source, target))
}

/// `math/geodesy.js`'s `metersPerDegreeLongitude`.
#[wasm_bindgen(js_name = metersPerDegreeLongitude)]
#[must_use]
pub fn meters_per_degree_longitude(latitude_degrees: &JsValue) -> f64 {
    geodesy::meters_per_degree_longitude(number(latitude_degrees, "geodesy: latitude"))
}

/// `math/geodesy.js`'s `tangentPlane`, a frozen object as that module returns.
#[wasm_bindgen(js_name = tangentPlane)]
#[must_use]
pub fn tangent_plane(options: &JsValue) -> JsValue {
    let reference = number_property(options, "referenceLatitudeDegrees");
    let tangent = geodesy::tangent_plane(reference);
    plane(
        tangent.reference_latitude_degrees,
        tangent.meters_per_degree_lon,
    )
}

/// `math/geodesy.js`'s `assertPlaneCovers`.
#[wasm_bindgen(js_name = assertPlaneCovers)]
pub fn assert_plane_covers(options: &JsValue) {
    let covered = property(options, "plane");
    geodesy::assert_plane_covers(geodesy::PlaneCoverage {
        plane: geodesy::TangentPlane {
            reference_latitude_degrees: number_property(&covered, "referenceLatitudeDegrees"),
            meters_per_degree_lon: number_property(&covered, "metersPerDegreeLon"),
        },
        latitude_degrees_min: number_property(options, "latitudeDegreesMin"),
        latitude_degrees_max: number_property(options, "latitudeDegreesMax"),
    });
}

/// `math/interpolation.js`'s `lerp`.
#[wasm_bindgen]
#[must_use]
pub fn lerp(options: &JsValue) -> f64 {
    let fraction = property(options, "fraction");
    interpolation::lerp(interpolation::Lerp {
        from: number_property(options, "from"),
        to: number_property(options, "to"),
        fraction: finite_number(&fraction, "interpolation: a fraction"),
    })
}

/// `math/interpolation.js`'s `clamp`.
#[wasm_bindgen]
#[must_use]
pub fn clamp(options: &JsValue) -> f64 {
    interpolation::clamp(interpolation::Clamp {
        value: number_property(options, "value"),
        min: number_property(options, "min"),
        max: number_property(options, "max"),
    })
}

/// `routing_snapshot.js`'s `FORMAT_VERSION`.
#[wasm_bindgen(js_name = routingSnapshotFormatVersion)]
#[must_use]
// wasm-bindgen exports no const fn.
#[expect(clippy::missing_const_for_fn)]
pub fn routing_snapshot_format_version() -> u16 {
    routing_snapshot::FORMAT_VERSION
}

/// `routing_snapshot.js`'s `POSITION_UNKNOWN_MICRODEGREES`.
#[wasm_bindgen(js_name = positionUnknownMicrodegrees)]
#[must_use]
// wasm-bindgen exports no const fn.
#[expect(clippy::missing_const_for_fn)]
pub fn position_unknown_microdegrees() -> i32 {
    routing_snapshot::POSITION_UNKNOWN_MICRODEGREES
}

/// `routing_snapshot.js`'s `DecodeKind`, a frozen object of the kinds' names.
#[wasm_bindgen(js_name = routingSnapshotDecodeKind)]
#[must_use]
pub fn routing_snapshot_decode_kind() -> JsValue {
    names(
        routing_snapshot::DecodeKind::ALL
            .map(|kind| kind.name().to_owned())
            .to_vec(),
    )
}

/// `routing_snapshot.js`'s `RefusalReason`, a frozen object of the reasons' names.
#[wasm_bindgen(js_name = routingSnapshotRefusalReason)]
#[must_use]
pub fn routing_snapshot_refusal_reason() -> JsValue {
    names(
        routing_snapshot::RefusalReason::ALL
            .map(|reason| reason.name().to_owned())
            .to_vec(),
    )
}

/// `routing_snapshot.js`'s `decodeStops`: the stop identifiers of a stops file.
#[wasm_bindgen(js_name = decodeStops)]
#[must_use]
pub fn decode_stops(buffer: &JsValue) -> JsValue {
    snapshot_result(
        routing_snapshot::decode_stops(&array_buffer_bytes(buffer)),
        |stop_ids| {
            let joined = Joined::of(stop_ids.iter().map(String::as_str));
            texts(&joined.text, joined.ends)
        },
    )
}

/// `routing_snapshot.js`'s `decodeTrips`: the trips of a trips file.
#[wasm_bindgen(js_name = decodeTrips)]
#[must_use]
pub fn decode_trips(buffer: &JsValue) -> JsValue {
    snapshot_result(
        routing_snapshot::decode_trips(&array_buffer_bytes(buffer)),
        |decoded_trips| {
            let ids = Joined::of(decoded_trips.iter().map(|trip| trip.id.as_str()));
            let route_ids = Joined::of(decoded_trips.iter().map(|trip| trip.route_id.as_str()));
            let offsets = decoded_trips
                .iter()
                .map(|trip| trip.service_day_offset)
                .collect();
            trips(
                &ids.text,
                ids.ends,
                &route_ids.text,
                route_ids.ends,
                offsets,
            )
        },
    )
}

// A column of strings as one text and the UTF-16 offset each string ends at,
// so the column crosses the binding as one string, which JavaScript slices
// apart, where each string crossing alone is decoded alone.
struct Joined {
    text: String,
    ends: Vec<u32>,
}

impl Joined {
    fn of<'text>(strings: impl ExactSizeIterator<Item = &'text str>) -> Self {
        let mut joined = Self {
            text: String::new(),
            ends: Vec::with_capacity(strings.len()),
        };
        let mut end: u32 = 0;
        for string in strings {
            joined.text.push_str(string);
            let units = u32::try_from(string.encode_utf16().count());
            let next = units.ok().and_then(|count| end.checked_add(count));
            let Some(next) = next else {
                assert::unreachable(&end, "binding: a file's text fits a u32 of UTF-16 units");
            };
            end = next;
            joined.ends.push(end);
        }
        joined
    }
}

/// `routing_snapshot.js`'s `decodeTransfers`: the walking links of a transfers
/// file, as typed arrays by column.
#[wasm_bindgen(js_name = decodeTransfers)]
#[must_use]
pub fn decode_transfers(buffer: &JsValue) -> JsValue {
    snapshot_result(
        routing_snapshot::decode_transfers(&array_buffer_bytes(buffer)),
        |links| transfers(links.from_stop, links.to_stop, links.duration_s),
    )
}

/// `routing_snapshot.js`'s `decodeConnections`: the connections of a
/// connections file, as typed arrays by column.
#[wasm_bindgen(js_name = decodeConnections)]
#[must_use]
pub fn decode_connections(buffer: &JsValue) -> JsValue {
    let bytes = array_buffer_bytes(buffer);
    snapshot_result(routing_snapshot::decode_connections(&bytes), |columns| {
        connections(
            columns.departure_s,
            columns.arrival_s,
            columns.departure_stop,
            columns.arrival_stop,
            columns.trip,
            columns.sequence,
            columns.boarding,
            columns.alighting,
        )
    })
}

/// `routing_snapshot.js`'s `decodePositions`: the stop positions of a
/// positions file, as typed arrays of microdegrees by axis.
#[wasm_bindgen(js_name = decodePositions)]
#[must_use]
pub fn decode_positions(buffer: &JsValue) -> JsValue {
    snapshot_result(
        routing_snapshot::decode_positions(&array_buffer_bytes(buffer)),
        |axes| positions(axes.lat_microdegrees, axes.lon_microdegrees),
    )
}

/// `packed_container.js`'s `PackedOutcome`, a frozen object of the outcomes' names.
#[wasm_bindgen(js_name = packedOutcome)]
#[must_use]
pub fn packed_outcome() -> JsValue {
    names(
        packed_container::Outcome::ALL
            .map(|outcome| outcome.name().to_owned())
            .to_vec(),
    )
}

/// `packed_container.js`'s `PackedRefusal`, a frozen object of the reasons' names.
#[wasm_bindgen(js_name = packedRefusal)]
#[must_use]
pub fn packed_refusal() -> JsValue {
    names(
        packed_container::Refusal::ALL
            .map(|reason| reason.name().to_owned())
            .to_vec(),
    )
}

/// `routing_walk.js`'s `WalkBasis`, a frozen object of the bases' names.
#[wasm_bindgen(js_name = routingWalkBasis)]
#[must_use]
pub fn routing_walk_basis() -> JsValue {
    names(
        routing_walk::WalkBasis::ALL
            .map(|basis| basis.name().to_owned())
            .to_vec(),
    )
}

/// `routing_walk.js`'s `WALK_CANDIDATE_COUNT_MAX`.
#[wasm_bindgen(js_name = walkCandidateCountMax)]
#[must_use]
// wasm-bindgen exports no const fn.
#[expect(clippy::missing_const_for_fn)]
pub fn walk_candidate_count_max() -> usize {
    routing_walk::WALK_CANDIDATE_COUNT_MAX
}

/// `routing_walk.js`'s `walkBasisOf`: the name of the basis of a manifest
/// entry's `transferRules`.
#[wasm_bindgen(js_name = walkBasisOf)]
#[must_use]
pub fn walk_basis_of(transfer_rules: &JsValue) -> String {
    let walk_basis = property(transfer_rules, "walkBasis").as_string();
    // A bound that is no number is `None`, read as no bound, as the
    // JavaScript's `Number.isFinite` reads it.
    let bound = property(transfer_rules, "walkStreetMetersMax").as_f64();
    let basis = routing_walk::walk_basis_of(walk_basis.as_deref(), bound);
    basis.name().to_owned()
}

/// `routing_walk.js`'s `isStreetWalk`: whether a walk is planned along the
/// streets under the basis `basis` names, which must be text.
#[wasm_bindgen(js_name = isStreetWalk)]
#[must_use]
pub fn is_street_walk(basis: &JsValue) -> bool {
    let Some(name) = basis.as_string() else {
        routing_walk::WalkBasis::refuse_unknown(&text(basis));
    };
    routing_walk::is_street_walk(routing_walk::WalkBasis::named(&name))
}

/// `routing_walk.js`'s `streetMetersMaxOf`: the street length a walk over the
/// streets may have under a manifest entry's `transferRules`.
#[wasm_bindgen(js_name = streetMetersMaxOf)]
#[must_use]
pub fn street_meters_max_of(transfer_rules: &JsValue) -> f64 {
    routing_walk::street_meters_max_of(street_bound(transfer_rules))
}

/// `routing_walk.js`'s `startsNear`: the start stops within walking distance
/// of a position, each `{stop, walkS}`.
#[wasm_bindgen(js_name = startsNear)]
#[must_use]
pub fn starts_near(options: &JsValue) -> JsValue {
    let near = NearValues::of(options);
    let found = routing_walk::starts_near(&near.query());
    starts_value(&found)
}

/// `routing_walk.js`'s `walkCandidatesNear`: the stops a walk over the streets
/// searches among, each `{stop, lat, lon}`.
#[wasm_bindgen(js_name = walkCandidatesNear)]
#[must_use]
pub fn walk_candidates_near(options: &JsValue) -> JsValue {
    let near = NearValues::of(options);
    let found = routing_walk::walk_candidates_near(&near.query());
    let mut stops = Vec::with_capacity(found.len());
    let mut lats = Vec::with_capacity(found.len());
    let mut lons = Vec::with_capacity(found.len());
    for candidate in &found {
        stops.push(candidate.stop);
        lats.push(candidate.lat);
        lons.push(candidate.lon);
    }
    caught(try_candidates(stops, lats, lons), "building candidates")
}

/// `routing_walk.js`'s `startsFromStreets`: the start stops of a walk over the
/// streets, each `{stop, walkS}`.
#[wasm_bindgen(js_name = startsFromStreets)]
#[must_use]
pub fn starts_from_streets(options: &JsValue) -> JsValue {
    let reached = reached_stops(&property(options, "stops"));
    let rules = walk_rules(&property(options, "transferRules"));
    let found = routing_walk::starts_from_streets(&reached, rules);
    starts_value(&found)
}

/// `trip_path.js`'s `TRIP_PATH_COUNT_MAX`.
#[wasm_bindgen(js_name = tripPathCountMax)]
#[must_use]
// wasm-bindgen exports no const fn.
#[expect(clippy::missing_const_for_fn)]
pub fn trip_path_count_max() -> usize {
    trip_path::TRIP_PATH_COUNT_MAX
}

/// `trip_path.js`'s `tripPathKey`: the key a path is held under.
#[wasm_bindgen(js_name = tripPathKey)]
#[must_use]
pub fn trip_path_key(options: &JsValue) -> String {
    let trip_id = trip_id_text(&property(options, "tripId"));
    let service_date_ms = date_number(&property(options, "serviceDateMs"));
    trip_path::trip_path_key(trip_path::KeyOf {
        trip_id: &trip_id,
        service_date_ms,
    })
}

/// `trip_path.js`'s `decodeTripPath`: one encoded path, decoded, a frozen
/// object of frozen points and stops.
#[wasm_bindgen(js_name = decodeTripPath)]
#[must_use]
pub fn decode_trip_path(path: &JsValue) -> JsValue {
    let points = encoded_text(&property(path, "points"));
    let stops = encoded_text(&property(path, "stops"));
    let trip_id_value = property(path, "trip_id");
    let route_id = property(path, "route_id");
    let service_date_value = property(path, "service_date_ms");
    let trip_id = trip_id_text(&trip_id_value);
    let decoded_path = trip_path::decode_trip_path(trip_path::EncodedPath {
        trip_id: &trip_id,
        service_date_ms: date_number(&service_date_value),
        points: &points,
        stops: &stops,
    });
    let mut coordinates = Vec::with_capacity(decoded_path.points.len().saturating_mul(2));
    for point in &decoded_path.points {
        coordinates.push(point.longitude);
        coordinates.push(point.latitude);
    }
    let mut stop_values = Vec::with_capacity(decoded_path.stops.len().saturating_mul(3));
    for stop in &decoded_path.stops {
        stop_values.push(stop.distance_meters);
        stop_values.push(stop.arrival_seconds);
        stop_values.push(stop.departure_seconds);
    }
    let parts = DecodedParts {
        trip_id: &trip_id_value,
        route_id: &route_id,
        service_date_ms: &service_date_value,
        key: &decoded_path.key,
    };
    decoded_trip_path(&parts, coordinates, stop_values)
}

/// `trip_path.js`'s `tripPathOf`: the decoded path its caller built, checked
/// and frozen with the arrays it was given.
#[wasm_bindgen(js_name = tripPathOf)]
#[must_use]
pub fn trip_path_of(options: &JsValue) -> JsValue {
    let trip_id_value = property(options, "tripId");
    let route_id = property(options, "routeId");
    let service_date_value = property(options, "serviceDateMs");
    let points = property(options, "points");
    let stops = property(options, "stops");
    let point_count = number_property(&points, "length");
    let stop_distances_meters = stop_distances(&stops);
    let trip_id = trip_id_text(&trip_id_value);
    let key = trip_path::trip_path_of(trip_path::TripPathParts {
        trip_id: &trip_id,
        service_date_ms: date_number(&service_date_value),
        point_count: length_of(point_count),
        stop_distances_meters: &stop_distances_meters,
    });
    let parts = DecodedParts {
        trip_id: &trip_id_value,
        route_id: &route_id,
        service_date_ms: &service_date_value,
        key: &key,
    };
    checked_trip_path(&parts, &points, &stops)
}

// Each stop's distance, which must be a number, as no coercion of a value a
// caller hands is made.
fn stop_distances(stops: &JsValue) -> Vec<f64> {
    let distances = caught(try_stop_distances(stops), "reading the stops");
    let mut meters = Vec::with_capacity(distances.len());
    for (index, distance) in distances.iter().enumerate() {
        let number = distance.as_f64();
        assert::condition(number.is_some(), || {
            format!(
                "binding: stop {index}'s distance {} is not a number",
                text(distance)
            )
        });
        meters.push(number.unwrap_or_default());
    }
    meters
}

// The result of a routing snapshot decoder: its records as `records` builds
// them, or its refusal.
fn snapshot_result<Records>(
    result: Result<Records, routing_snapshot::RefusalReason>,
    records: impl FnOnce(Records) -> JsValue,
) -> JsValue {
    match result {
        Ok(decoded_records) => decoded(
            routing_snapshot::DecodeKind::Decoded.name(),
            records(decoded_records),
        ),
        Err(reason) => refusal(routing_snapshot::DecodeKind::Refused.name(), reason.name()),
    }
}

// The bytes of `buffer`, which must be an `ArrayBuffer`, as the JavaScript
// readers read one, copied into the module's memory once.
fn array_buffer_bytes(buffer: &JsValue) -> Vec<u8> {
    let type_name = caught(try_type_name(buffer), "naming the bytes' type");
    assert::condition(type_name == ARRAY_BUFFER_TYPE_NAME, || {
        format!("binding: the bytes are an {type_name}, not an ArrayBuffer")
    });
    caught(try_buffer_bytes(buffer), "reading the bytes")
}

// The name `Object.prototype.toString` gives an `ArrayBuffer`.
const ARRAY_BUFFER_TYPE_NAME: &str = "[object ArrayBuffer]";

// The text of encoded numbers, which must be text.
fn encoded_text(value: &JsValue) -> String {
    let encoded = value.as_string();
    assert::condition(encoded.is_some(), || {
        trip_path::ENCODED_NOT_TEXT_MESSAGE.to_owned()
    });
    encoded.unwrap_or_default()
}

// The text of a trip identifier, which must be text.
fn trip_id_text(value: &JsValue) -> String {
    let trip_id = value.as_string();
    assert::condition(trip_id.is_some(), || {
        trip_path::TRIP_ID_NOT_TEXT_MESSAGE.to_owned()
    });
    trip_id.unwrap_or_default()
}

// A service date as a number; a value that is none is NaN, which the core
// refuses as no integer, as the JavaScript's `Number.isSafeInteger` does.
fn date_number(value: &JsValue) -> f64 {
    value.as_f64().unwrap_or(f64::NAN)
}

// An array's length, a whole count, which its decimal text reads back as.
fn length_of(length: f64) -> usize {
    let count = number_text(length).parse::<usize>();
    assert::condition(count.is_ok(), || {
        format!("binding: a length {} is not a count", number_text(length))
    });
    count.unwrap_or_default()
}

// The value of a read that JavaScript may throw from, and an assertion's
// failure where it throws; `name` names what was read.
fn caught<Value: Default>(read: Result<Value, JsValue>, name: &str) -> Value {
    let failure = read.as_ref().err().map(text);
    assert::condition(failure.is_none(), || {
        format!("binding: {name} threw {}", failure.unwrap_or_default())
    });
    read.unwrap_or_default()
}

fn plane(reference_latitude_degrees: f64, meters_per_degree_lon: f64) -> JsValue {
    caught(
        try_plane(reference_latitude_degrees, meters_per_degree_lon),
        "building a plane",
    )
}

fn names(list: Vec<String>) -> JsValue {
    caught(try_names(list), "building names")
}

fn refusal(kind: &str, reason: &str) -> JsValue {
    caught(try_refusal(kind, reason), "building a refusal")
}

fn decoded(kind: &str, records: JsValue) -> JsValue {
    caught(try_decoded(kind, records), "building a result")
}

fn texts(text: &str, ends: Vec<u32>) -> JsValue {
    caught(try_texts(text, ends), "building texts")
}

fn trips(
    id_text: &str,
    id_ends: Vec<u32>,
    route_text: &str,
    route_ends: Vec<u32>,
    offsets: Vec<u8>,
) -> JsValue {
    caught(
        try_trips(id_text, id_ends, route_text, route_ends, offsets),
        "building trips",
    )
}

fn transfers(from_stop: Vec<u32>, to_stop: Vec<u32>, duration_s: Vec<u32>) -> JsValue {
    caught(
        try_transfers(from_stop, to_stop, duration_s),
        "building transfers",
    )
}

#[expect(
    clippy::too_many_arguments,
    reason = "a connections file has eight columns"
)]
fn connections(
    departure_s: Vec<i32>,
    arrival_s: Vec<i32>,
    departure_stop: Vec<u32>,
    arrival_stop: Vec<u32>,
    trip: Vec<u32>,
    sequence: Vec<u16>,
    boarding: Vec<u8>,
    alighting: Vec<u8>,
) -> JsValue {
    caught(
        try_connections(
            departure_s,
            arrival_s,
            departure_stop,
            arrival_stop,
            trip,
            sequence,
            boarding,
            alighting,
        ),
        "building connections",
    )
}

fn positions(lat_microdegrees: Vec<i32>, lon_microdegrees: Vec<i32>) -> JsValue {
    caught(
        try_positions(lat_microdegrees, lon_microdegrees),
        "building positions",
    )
}

// A decoded path's parts as `decodeTripPath` returns them.
struct DecodedParts<'path> {
    trip_id: &'path JsValue,
    route_id: &'path JsValue,
    service_date_ms: &'path JsValue,
    key: &'path str,
}

fn decoded_trip_path(
    parts: &DecodedParts<'_>,
    coordinates: Vec<f64>,
    stop_values: Vec<f64>,
) -> JsValue {
    caught(
        try_decoded_trip_path(
            parts.trip_id,
            parts.route_id,
            parts.service_date_ms,
            parts.key,
            coordinates,
            stop_values,
        ),
        "building a path",
    )
}

fn checked_trip_path(parts: &DecodedParts<'_>, points: &JsValue, stops: &JsValue) -> JsValue {
    caught(
        try_checked_trip_path(
            parts.trip_id,
            parts.route_id,
            parts.service_date_ms,
            parts.key,
            points,
            stops,
        ),
        "building a path",
    )
}

// The arguments of a walk near a position, read from the options object.
struct NearValues {
    position: geodesy::Position,
    positions: routing_snapshot::Positions,
    rules: routing_walk::WalkRules,
}

impl NearValues {
    fn of(options: &JsValue) -> Self {
        let position = property(options, "position");
        let positions = property(options, "positions");
        Self {
            position: geodesy::Position {
                lon: number(
                    &property(&position, "lon"),
                    "binding: routing walk: the position's lon",
                ),
                lat: number(
                    &property(&position, "lat"),
                    "binding: routing walk: the position's lat",
                ),
            },
            positions: routing_snapshot::Positions {
                lat_microdegrees: int32_column(&property(&positions, "latMicrodegrees")),
                lon_microdegrees: int32_column(&property(&positions, "lonMicrodegrees")),
            },
            rules: walk_rules(&property(options, "transferRules")),
        }
    }

    const fn query(&self) -> routing_walk::Near<'_> {
        routing_walk::Near {
            position: self.position,
            positions: &self.positions,
            rules: self.rules,
        }
    }
}

// The walking rules of a manifest entry's `transferRules`, each a number.
fn walk_rules(transfer_rules: &JsValue) -> routing_walk::WalkRules {
    routing_walk::WalkRules {
        walk_radius_m: number(
            &property(transfer_rules, "walkRadiusM"),
            "binding: routing walk: walkRadiusM",
        ),
        walk_speed_m_per_s: number(
            &property(transfer_rules, "walkSpeedMPerS"),
            "binding: routing walk: walkSpeedMPerS",
        ),
        walk_link_count_per_stop_max: number(
            &property(transfer_rules, "walkLinkCountPerStopMax"),
            "binding: routing walk: walkLinkCountPerStopMax",
        ),
    }
}

// A manifest entry's `walkStreetMetersMax`, which must be a number where the
// entry holds one.
fn street_bound(transfer_rules: &JsValue) -> Option<f64> {
    let bound = property(transfer_rules, "walkStreetMetersMax");
    if bound.is_undefined() {
        return None;
    }
    Some(number(&bound, "binding: routing walk: walkStreetMetersMax"))
}

// A column of a decoded positions file, which must be an `Int32Array`, copied
// into the module's memory.
fn int32_column(column: &JsValue) -> Vec<i32> {
    let type_name = caught(try_type_name(column), "naming the column's type");
    assert::condition(type_name == INT32_ARRAY_TYPE_NAME, || {
        format!("binding: a position column is an {type_name}, not an Int32Array")
    });
    caught(try_int32s(column), "reading a position column")
}

// The name `Object.prototype.toString` gives an `Int32Array`.
const INT32_ARRAY_TYPE_NAME: &str = "[object Int32Array]";

// The stops of a reach, each `{stop, streetM}` of two numbers, as no coercion
// of a value a caller hands is made.
fn reached_stops(stops: &JsValue) -> Vec<routing_walk::ReachedStop> {
    let values = caught(try_reached_values(stops), "reading the reached stops");
    let (pairs, _) = values.as_chunks::<2>();
    let mut reached = Vec::with_capacity(pairs.len());
    for (index, [stop, street_m]) in pairs.iter().enumerate() {
        reached.push(routing_walk::ReachedStop {
            stop: number(
                stop,
                &format!("binding: routing walk: reached stop {index}'s stop"),
            ),
            street_m: number(
                street_m,
                &format!("binding: routing walk: reached stop {index}'s streetM"),
            ),
        });
    }
    reached
}

fn starts_value(found: &[routing_walk::Start]) -> JsValue {
    let mut stops = Vec::with_capacity(found.len());
    let mut walk_seconds = Vec::with_capacity(found.len());
    for start in found {
        stops.push(start.stop);
        walk_seconds.push(start.walk_s);
    }
    caught(try_starts(stops, walk_seconds), "building starts")
}

// The pair of positions `[lon, lat]` the JavaScript module destructures.
fn between(source: &JsValue, target: &JsValue) -> geodesy::Between {
    geodesy::Between {
        source: position_of(source),
        target: position_of(target),
    }
}

fn position_of(value: &JsValue) -> geodesy::Position {
    let label = "geodesy: a position";
    geodesy::Position {
        lon: coordinate(value, geodesy::Axis::Longitude, label),
        lat: coordinate(value, geodesy::Axis::Latitude, label),
    }
}

// The coordinate on `axis` of the array `position`, which must be a number.
fn coordinate(position: &JsValue, axis: geodesy::Axis, label: &str) -> f64 {
    let index = match axis {
        geodesy::Axis::Longitude => "0",
        geodesy::Axis::Latitude => "1",
    };
    let value = property(position, index);
    let coordinate = value.as_f64();
    assert::condition(coordinate.is_some(), || {
        geodesy::not_a_coordinate_message(label, axis, &text(&value))
    });
    let Some(coordinate) = coordinate else {
        assert::unreachable(
            &index,
            "binding: a coordinate checked to be a number is one",
        );
    };
    coordinate
}

// The number the property `key` of `options` holds, which must be one.
fn number_property(options: &JsValue, key: &str) -> f64 {
    let value = property(options, key);
    number(&value, key)
}

// The number `value` is, which must be one; `name` names it in a failure.
fn number(value: &JsValue, name: &str) -> f64 {
    let number = value.as_f64();
    assert::condition(number.is_some(), || {
        format!("{name} {} is not a number", text(value))
    });
    let Some(number) = number else {
        assert::unreachable(&name, "binding: a value checked to be a number is one");
    };
    number
}

// The number `value` is, which must be one, refused with the message of the
// core's `assert_finite` where it is none.
fn finite_number(value: &JsValue, label: &str) -> f64 {
    let number = value.as_f64();
    assert::condition(number.is_some(), || {
        checks::not_finite_message(label, &text(value))
    });
    let Some(number) = number else {
        assert::unreachable(&label, "binding: a value checked to be a number is one");
    };
    number
}

// `target[key]`, and an assertion's failure where reading it throws, as it
// does for a `target` that is `null` or `undefined`.
fn property(target: &JsValue, key: &str) -> JsValue {
    let read = try_property(target, key);
    let failure = read.as_ref().err().map(text);
    assert::condition(failure.is_none(), || {
        format!(
            "binding: reading {key} threw {}",
            failure.unwrap_or_default()
        )
    });
    read.unwrap_or_default()
}

// `String(value)`, and an assertion's failure where the conversion throws.
fn text(value: &JsValue) -> String {
    let converted = try_js_string(value);
    let written = converted.as_ref().ok().and_then(JsValue::as_string);
    assert::condition(written.is_some(), || {
        "binding: a value String cannot write".to_owned()
    });
    written.unwrap_or_default()
}

#[cfg(test)]
mod tests {
    // The binding passes the core's value through unchanged.
    #[test]
    fn core_version_is_the_core_version() {
        assert_eq!(super::core_version(), gobusgo_core::core_version());
    }
}
