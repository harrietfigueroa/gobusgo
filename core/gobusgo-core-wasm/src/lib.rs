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
use wasm_bindgen::prelude::{JsValue, wasm_bindgen};

// The length of an array that holds a position's two coordinates.
const COORDINATE_COUNT: f64 = 2.0;

/// The version of the core this module was built from.
#[wasm_bindgen(js_name = coreVersion)]
#[must_use]
pub fn core_version() -> String {
    gobusgo_core::core_version().to_owned()
}

// The failure every assertion throws; the frozen object a tangent plane crosses
// as, which JavaScript builds so that no value a caller holds points into the
// module's memory; and a property read as JavaScript reads `target[key]`.
#[wasm_bindgen(inline_js = "
export class AssertionError extends Error {}
export function assertionError(message) { return new AssertionError(message) }
export function plane(referenceLatitudeDegrees, metersPerDegreeLon) {
  return Object.freeze({referenceLatitudeDegrees, metersPerDegreeLon})
}
export function property(target, key) { return target[key] }
")]
extern "C" {
    #[wasm_bindgen(thread_local_v2, js_name = AssertionError)]
    static ASSERTION_ERROR_CLASS: JsValue;

    #[wasm_bindgen(js_name = assertionError)]
    fn assertion_error(message: &str) -> JsValue;

    fn plane(reference_latitude_degrees: f64, meters_per_degree_lon: f64) -> JsValue;

    #[wasm_bindgen(catch, js_name = property)]
    fn try_property(target: &JsValue, key: &str) -> Result<JsValue, JsValue>;
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
    let error = assertion_error(&message);
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
