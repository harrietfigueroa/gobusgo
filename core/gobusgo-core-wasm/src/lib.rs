//! The core's binding for the web. Each export converts its arguments and result
//! across wasm-bindgen and holds no logic of its own. An export takes the
//! arguments the JavaScript module of the same name takes, an options object
//! read through its properties where that module takes one, so a stand-in for
//! the module renames nothing.
//!
//! A failed assertion of the core throws this module's `AssertionError`, which
//! `assertionErrorClass` returns, with the core's message.

use gobusgo_core::assert::{self, AssertionError as CoreAssertionError};
use gobusgo_core::math::{angles, checks, geodesy, interpolation};
use wasm_bindgen::prelude::{JsValue, wasm_bindgen};

/// The version of the core this module was built from.
#[wasm_bindgen(js_name = coreVersion)]
#[must_use]
pub fn core_version() -> String {
    gobusgo_core::core_version().to_owned()
}

// The failure every assertion throws, and the frozen object a tangent plane
// crosses as, which JavaScript builds so that no value a caller holds points
// into the module's memory.
#[wasm_bindgen(inline_js = "
export class AssertionError extends Error {}
export function assertionError(message) { return new AssertionError(message) }
export function plane(referenceLatitudeDegrees, metersPerDegreeLon) {
  return Object.freeze({referenceLatitudeDegrees, metersPerDegreeLon})
}
")]
extern "C" {
    #[wasm_bindgen(thread_local_v2, js_name = AssertionError)]
    static ASSERTION_ERROR_CLASS: JsValue;

    #[wasm_bindgen(js_name = assertionError)]
    fn assertion_error(message: &str) -> JsValue;

    fn plane(reference_latitude_degrees: f64, meters_per_degree_lon: f64) -> JsValue;
}

// JavaScript's own conversions: `String(value)`, and the coordinates of an
// array as doubles, which is empty for a value no array.
#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_name = String)]
    fn js_string(value: &JsValue) -> String;

    #[wasm_bindgen(js_namespace = Float64Array, js_name = from)]
    fn float64_array_from(value: &JsValue) -> Vec<f64>;
}

// The options objects the JavaScript modules take, read through their
// properties.
#[wasm_bindgen]
extern "C" {
    pub type OrderedOptions;
    #[wasm_bindgen(method, getter)]
    fn low(this: &OrderedOptions) -> f64;
    #[wasm_bindgen(method, getter)]
    fn high(this: &OrderedOptions) -> f64;
    #[wasm_bindgen(method, getter)]
    fn label(this: &OrderedOptions) -> String;

    pub type TurnOptions;
    #[wasm_bindgen(method, getter)]
    fn from(this: &TurnOptions) -> f64;
    #[wasm_bindgen(method, getter)]
    fn to(this: &TurnOptions) -> f64;

    pub type LerpOptions;
    #[wasm_bindgen(method, getter)]
    fn from(this: &LerpOptions) -> f64;
    #[wasm_bindgen(method, getter)]
    fn to(this: &LerpOptions) -> f64;
    #[wasm_bindgen(method, getter)]
    fn fraction(this: &LerpOptions) -> f64;

    pub type ClampOptions;
    #[wasm_bindgen(method, getter)]
    fn value(this: &ClampOptions) -> f64;
    #[wasm_bindgen(method, getter)]
    fn min(this: &ClampOptions) -> f64;
    #[wasm_bindgen(method, getter)]
    fn max(this: &ClampOptions) -> f64;

    pub type PlaneOptions;
    #[wasm_bindgen(method, getter = referenceLatitudeDegrees)]
    fn reference_latitude_degrees(this: &PlaneOptions) -> f64;

    pub type Plane;
    #[wasm_bindgen(method, getter = referenceLatitudeDegrees)]
    fn reference_latitude_degrees(this: &Plane) -> f64;
    #[wasm_bindgen(method, getter = metersPerDegreeLon)]
    fn meters_per_degree_lon(this: &Plane) -> f64;

    pub type CoverageOptions;
    #[wasm_bindgen(method, getter)]
    fn plane(this: &CoverageOptions) -> Plane;
    #[wasm_bindgen(method, getter = latitudeDegreesMin)]
    fn latitude_degrees_min(this: &CoverageOptions) -> f64;
    #[wasm_bindgen(method, getter = latitudeDegreesMax)]
    fn latitude_degrees_max(this: &CoverageOptions) -> f64;
}

// A panic of the core throws the AssertionError with its message, and the
// instance is made anew before the next call: the throw leaves the panic
// unfinished, with the module's stack and its count of panics where the panic
// left them.
//
// An export takes text as a `JsValue` and reads it through `String` inside the
// call. The loader wasm-bindgen 0.2.130 writes copies a `&str` argument into
// the module's memory with `passStringToWasm0` before `__wbg_call_guard` makes
// the instance anew, so the first call after a failure reads that text from
// the new instance's memory, where it is not.
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
    assert::condition(condition.is_truthy(), || js_string(message));
}

/// `assert.js`'s `unreachable`: throws naming `value` as `String(value)` writes it.
#[wasm_bindgen]
pub fn unreachable(value: &JsValue, message: &JsValue) {
    let text = js_string(value);
    assert::unreachable(&text, &js_string(message));
}

/// `math/checks.js`'s `assertFinite`.
#[wasm_bindgen(js_name = assertFinite)]
pub fn assert_finite(value: f64, label: &JsValue) {
    checks::assert_finite(value, &js_string(label));
}

/// `math/checks.js`'s `assertOrdered`.
#[wasm_bindgen(js_name = assertOrdered)]
pub fn assert_ordered(options: &OrderedOptions) {
    let label = options.label();
    checks::assert_ordered(checks::Ordered {
        low: options.low(),
        high: options.high(),
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
pub fn radians(degrees: f64) -> f64 {
    angles::radians(degrees)
}

/// `math/angles.js`'s `degrees`.
#[wasm_bindgen]
#[must_use]
pub fn degrees(radians: f64) -> f64 {
    angles::degrees(radians)
}

/// `math/angles.js`'s `normalizedDegrees`.
#[wasm_bindgen(js_name = normalizedDegrees)]
#[must_use]
pub fn normalized_degrees(degrees: f64) -> f64 {
    angles::normalized_degrees(degrees)
}

/// `math/angles.js`'s `turnDegrees`.
#[wasm_bindgen(js_name = turnDegrees)]
#[must_use]
pub fn turn_degrees(options: &TurnOptions) -> f64 {
    angles::turn_degrees(angles::Turn {
        from: options.from(),
        to: options.to(),
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

/// `math/geodesy.js`'s `assertPosition`: `position` must be an array, and its
/// coordinates a position.
#[wasm_bindgen(js_name = assertPosition)]
pub fn assert_position(position: &JsValue, label: &JsValue) {
    let label = js_string(label);
    assert::condition(position.is_array(), || {
        format!("{label}: a position is [lon, lat]")
    });
    let coordinates = float64_array_from(position);
    let _ = geodesy::assert_position(&coordinates, &label);
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
pub fn meters_per_degree_longitude(latitude_degrees: f64) -> f64 {
    geodesy::meters_per_degree_longitude(latitude_degrees)
}

/// `math/geodesy.js`'s `tangentPlane`, a frozen object as that module returns.
#[wasm_bindgen(js_name = tangentPlane)]
#[must_use]
pub fn tangent_plane(options: &PlaneOptions) -> JsValue {
    let tangent = geodesy::tangent_plane(options.reference_latitude_degrees());
    plane(
        tangent.reference_latitude_degrees,
        tangent.meters_per_degree_lon,
    )
}

/// `math/geodesy.js`'s `assertPlaneCovers`.
#[wasm_bindgen(js_name = assertPlaneCovers)]
pub fn assert_plane_covers(options: &CoverageOptions) {
    let covered = options.plane();
    geodesy::assert_plane_covers(geodesy::PlaneCoverage {
        plane: geodesy::TangentPlane {
            reference_latitude_degrees: covered.reference_latitude_degrees(),
            meters_per_degree_lon: covered.meters_per_degree_lon(),
        },
        latitude_degrees_min: options.latitude_degrees_min(),
        latitude_degrees_max: options.latitude_degrees_max(),
    });
}

/// `math/interpolation.js`'s `lerp`.
#[wasm_bindgen]
#[must_use]
pub fn lerp(options: &LerpOptions) -> f64 {
    interpolation::lerp(interpolation::Lerp {
        from: options.from(),
        to: options.to(),
        fraction: options.fraction(),
    })
}

/// `math/interpolation.js`'s `clamp`.
#[wasm_bindgen]
#[must_use]
pub fn clamp(options: &ClampOptions) -> f64 {
    interpolation::clamp(interpolation::Clamp {
        value: options.value(),
        min: options.min(),
        max: options.max(),
    })
}

// The pair of positions `[lon, lat]` the JavaScript module destructures, a
// missing coordinate reading as no number as it does there.
fn between(source: &JsValue, target: &JsValue) -> geodesy::Between {
    geodesy::Between {
        source: position_of(source),
        target: position_of(target),
    }
}

fn position_of(value: &JsValue) -> geodesy::Position {
    let coordinates = float64_array_from(value);
    let mut numbers = coordinates.iter().copied();
    let lon = numbers.next().unwrap_or(f64::NAN);
    let lat = numbers.next().unwrap_or(f64::NAN);
    geodesy::Position { lon, lat }
}

#[cfg(test)]
mod tests {
    // The binding passes the core's value through unchanged.
    #[test]
    fn core_version_is_the_core_version() {
        assert_eq!(super::core_version(), gobusgo_core::core_version());
    }

    // A conversion that crosses as plain doubles passes the core's value
    // through unchanged.
    #[test]
    fn radians_are_the_core_radians() {
        let degrees = 47.6062;
        assert_eq!(
            super::radians(degrees),
            gobusgo_core::math::angles::radians(degrees)
        );
    }
}
