//! The core's binding for Swift and Kotlin. Each export converts its arguments
//! and result across uniffi and holds no logic of its own. A record here mirrors
//! a struct of the core field for field, since the core takes no crate and so
//! derives none of uniffi's traits.
//!
//! A failed assertion of the core aborts the app, as the release profile aborts
//! on every panic: an assertion's failure is a programmer error, and a native
//! caller handles none.

use gobusgo_core::math::{angles, checks, geodesy, interpolation};

uniffi::setup_scaffolding!();

/// The version of the core this library was built from.
#[uniffi::export]
#[must_use]
pub fn core_version() -> String {
    gobusgo_core::core_version().to_owned()
}

/// A pair of numbers that must be in order, and the label that names them.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Ordered {
    pub low: f64,
    pub high: f64,
    pub label: String,
}

/// Two compass directions in degrees, the one turned from and the one turned to.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct Turn {
    pub from: f64,
    pub to: f64,
}

/// A line from `from` to `to`, and the share of the way along it to go.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct Lerp {
    pub from: f64,
    pub to: f64,
    pub fraction: f64,
}

/// A value and the bounds to bring it inside, both included.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct Clamp {
    pub value: f64,
    pub min: f64,
    pub max: f64,
}

/// A position on the Earth, in degrees.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct Position {
    pub lon: f64,
    pub lat: f64,
}

/// Two positions, the one a measure starts from and the one it ends at.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct Between {
    pub source: Position,
    pub target: Position,
}

/// A plane tangent at a latitude, with the meters of a degree of longitude on it.
#[derive(Debug, Clone, Copy, PartialEq, uniffi::Record)]
pub struct TangentPlane {
    pub reference_latitude_degrees: f64,
    pub meters_per_degree_lon: f64,
}

/// A plane and the span of latitudes it must measure.
#[derive(Debug, Clone, Copy, uniffi::Record)]
pub struct PlaneCoverage {
    pub plane: TangentPlane,
    pub latitude_degrees_min: f64,
    pub latitude_degrees_max: f64,
}

impl From<Position> for geodesy::Position {
    fn from(position: Position) -> Self {
        Self {
            lon: position.lon,
            lat: position.lat,
        }
    }
}

impl From<geodesy::Position> for Position {
    fn from(position: geodesy::Position) -> Self {
        Self {
            lon: position.lon,
            lat: position.lat,
        }
    }
}

impl From<Between> for geodesy::Between {
    fn from(between: Between) -> Self {
        Self {
            source: between.source.into(),
            target: between.target.into(),
        }
    }
}

impl From<TangentPlane> for geodesy::TangentPlane {
    fn from(plane: TangentPlane) -> Self {
        Self {
            reference_latitude_degrees: plane.reference_latitude_degrees,
            meters_per_degree_lon: plane.meters_per_degree_lon,
        }
    }
}

impl From<geodesy::TangentPlane> for TangentPlane {
    fn from(plane: geodesy::TangentPlane) -> Self {
        Self {
            reference_latitude_degrees: plane.reference_latitude_degrees,
            meters_per_degree_lon: plane.meters_per_degree_lon,
        }
    }
}

/// Asserts that `value` is a finite number; `label` names it in a failure.
#[uniffi::export]
pub fn assert_finite(value: f64, label: &str) {
    checks::assert_finite(value, label);
}

/// Asserts that `low` is at most `high`.
#[uniffi::export]
pub fn assert_ordered(ordered: Ordered) {
    let Ordered { low, high, label } = ordered;
    checks::assert_ordered(checks::Ordered {
        low,
        high,
        label: &label,
    });
}

/// The degrees of a whole turn.
#[uniffi::export]
#[must_use]
pub const fn degrees_per_turn() -> f64 {
    angles::DEGREES_PER_TURN
}

/// The degrees of a half turn, which is π radians.
#[uniffi::export]
#[must_use]
pub const fn degrees_per_half_turn() -> f64 {
    angles::DEGREES_PER_HALF_TURN
}

/// `degrees` in radians.
#[uniffi::export]
#[must_use]
pub fn radians(degrees: f64) -> f64 {
    angles::radians(degrees)
}

/// `radians` in degrees.
#[uniffi::export]
#[must_use]
pub fn degrees(radians: f64) -> f64 {
    angles::degrees(radians)
}

/// `degrees` turned into the range from 0 up to, and not including, 360.
#[uniffi::export]
#[must_use]
pub fn normalized_degrees(degrees: f64) -> f64 {
    angles::normalized_degrees(degrees)
}

/// The smaller angle between two directions, from 0 to 180 degrees.
#[uniffi::export]
#[must_use]
pub fn turn_degrees(turn: Turn) -> f64 {
    angles::turn_degrees(angles::Turn {
        from: turn.from,
        to: turn.to,
    })
}

/// The mean radius of the Earth in meters.
#[uniffi::export]
#[must_use]
pub const fn earth_radius_meters() -> f64 {
    geodesy::EARTH_RADIUS_METERS
}

/// The meters of a degree of latitude, and of a degree of longitude at the equator.
#[uniffi::export]
#[must_use]
pub const fn meters_per_degree() -> f64 {
    geodesy::METERS_PER_DEGREE
}

/// The most a tangent plane's longitude scale may be off at a latitude it covers.
#[uniffi::export]
#[must_use]
pub const fn plane_scale_error_max() -> f64 {
    geodesy::PLANE_SCALE_ERROR_MAX
}

/// The position `coordinates` hold, a longitude and a latitude in degrees.
#[uniffi::export]
#[must_use]
pub fn assert_position(coordinates: &[f64], label: &str) -> Position {
    geodesy::assert_position(coordinates, label).into()
}

/// The great-circle distance in meters between two positions.
#[uniffi::export]
#[must_use]
pub fn distance_meters(between: Between) -> f64 {
    geodesy::distance_meters(between.into())
}

/// The initial great-circle bearing between two positions, in degrees from north.
#[uniffi::export]
#[must_use]
pub fn initial_bearing_degrees(between: Between) -> f64 {
    geodesy::initial_bearing_degrees(between.into())
}

/// The meters of a degree of longitude at `latitude_degrees`.
#[uniffi::export]
#[must_use]
pub fn meters_per_degree_longitude(latitude_degrees: f64) -> f64 {
    geodesy::meters_per_degree_longitude(latitude_degrees)
}

/// The plane tangent at `reference_latitude_degrees`.
#[uniffi::export]
#[must_use]
pub fn tangent_plane(reference_latitude_degrees: f64) -> TangentPlane {
    geodesy::tangent_plane(reference_latitude_degrees).into()
}

/// Asserts that a plane measures every latitude of a span closely enough.
#[uniffi::export]
pub fn assert_plane_covers(coverage: PlaneCoverage) {
    geodesy::assert_plane_covers(geodesy::PlaneCoverage {
        plane: coverage.plane.into(),
        latitude_degrees_min: coverage.latitude_degrees_min,
        latitude_degrees_max: coverage.latitude_degrees_max,
    });
}

/// The value `fraction` of the way from `from` to `to`.
#[uniffi::export]
#[must_use]
pub fn lerp(line: Lerp) -> f64 {
    interpolation::lerp(interpolation::Lerp {
        from: line.from,
        to: line.to,
        fraction: line.fraction,
    })
}

/// `value` brought inside `min` and `max`, both included.
#[uniffi::export]
#[must_use]
pub fn clamp(bounds: Clamp) -> f64 {
    interpolation::clamp(interpolation::Clamp {
        value: bounds.value,
        min: bounds.min,
        max: bounds.max,
    })
}

#[cfg(test)]
mod tests {
    // The binding passes the core's value through unchanged.
    #[test]
    fn core_version_is_the_core_version() {
        assert_eq!(super::core_version(), gobusgo_core::core_version());
    }

    // A record crosses field for field, so a plane comes back as the core's.
    #[test]
    fn tangent_plane_is_the_core_plane() {
        let reference = 47.6062;
        let plane: gobusgo_core::math::geodesy::TangentPlane =
            super::tangent_plane(reference).into();
        assert_eq!(plane, gobusgo_core::math::geodesy::tangent_plane(reference));
    }
}
