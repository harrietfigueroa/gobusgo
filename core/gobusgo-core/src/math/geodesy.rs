//! Distances and directions on the Earth, taken as a sphere of the mean radius.
//! Everything here is pure. A position is a longitude and a latitude in
//! degrees.
//!
//! A distance on the sphere is within 0.5% of one on the ellipsoid.

use std::f64::consts::PI;

use super::angles::{DEGREES_PER_HALF_TURN, degrees, normalized_degrees, radians};
use super::checks::{Ordered, assert_ordered};
use crate::assert::{self, number_text};

/// The mean radius of the Earth, IUGG's R1 of 6,371,008.7714 m for the GRS 80
/// ellipsoid rounded to the decimeter.
/// <https://en.wikipedia.org/wiki/Earth_radius#Arithmetic_mean_radius> — checked 2026-11-09
pub const EARTH_RADIUS_METERS: f64 = 6_371_008.8;

/// The meters of a degree of latitude, and of a degree of longitude at the equator.
pub const METERS_PER_DEGREE: f64 = PI * EARTH_RADIUS_METERS / DEGREES_PER_HALF_TURN;

/// The most a tangent plane's longitude scale may be off at a latitude it
/// covers, as a share of the true scale: 2% of an east-west offset of 100 m is
/// 2 m, finer than a reported vehicle position.
pub const PLANE_SCALE_ERROR_MAX: f64 = 0.02;

const LONGITUDE_DEGREES_MAX: f64 = 180.0;
const LATITUDE_DEGREES_MAX: f64 = 90.0;
const COORDINATE_COUNT: usize = 2;
const HALF: f64 = 2.0;

/// A position on the Earth, in degrees.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Position {
    pub lon: f64,
    pub lat: f64,
}

/// Asserts that `coordinates` are a longitude and a latitude in degrees, in
/// that order, the order of `GeoJSON` and `MapLibre`, and returns them as a
/// position; `label` names them in a failure.
#[must_use]
#[track_caller]
pub fn assert_position(coordinates: &[f64], label: &str) -> Position {
    let coordinate_count = coordinates.len();
    assert::condition(coordinate_count == COORDINATE_COUNT, || {
        format!("{label}: a position has two coordinates, not {coordinate_count}")
    });
    let &[lon, lat] = coordinates else {
        assert::unreachable(&coordinate_count, "geodesy: two coordinates are a pair");
    };
    assert::condition(lon.is_finite(), || {
        format!("{label}: longitude {} is not a number", number_text(lon))
    });
    assert::condition(lat.is_finite(), || {
        format!("{label}: latitude {} is not a number", number_text(lat))
    });
    assert::condition(lon.abs() <= LONGITUDE_DEGREES_MAX, || {
        format!("{label}: longitude {} is out of range", number_text(lon))
    });
    assert::condition(lat.abs() <= LATITUDE_DEGREES_MAX, || {
        format!("{label}: latitude {} is out of range", number_text(lat))
    });
    Position { lon, lat }
}

/// Two positions, the one a measure starts from and the one it ends at.
#[derive(Debug, Clone, Copy)]
pub struct Between {
    pub source: Position,
    pub target: Position,
}

/// The great-circle distance in meters between `source` and `target`.
///
/// It is the haversine formula, which keeps its precision at the short
/// distances a city holds. A pair across the antimeridian is measured the short
/// way round.
#[must_use]
#[track_caller]
pub fn distance_meters(between: Between) -> f64 {
    let Between { source, target } = between;
    let lat_delta = radians(target.lat - source.lat);
    let lon_delta = radians(target.lon - source.lon);
    let sin_lat = (lat_delta / HALF).sin();
    let sin_lon = (lon_delta / HALF).sin();
    let source_cosine = radians(source.lat).cos();
    let target_cosine = radians(target.lat).cos();
    // A fused multiply-add rounds once where JavaScript rounds each product
    // and the sum, so the sum is written out to give the JavaScript core's bits.
    #[expect(clippy::suboptimal_flops)]
    let chord = sin_lat * sin_lat + source_cosine * target_cosine * sin_lon * sin_lon;
    // The haversine sum can round past 1 for antipodal positions, where arcsine
    // has no value.
    let root = chord.sqrt();
    let half_angle_sine = if root > 1.0 { 1.0 } else { root };
    let meters = HALF * EARTH_RADIUS_METERS * half_angle_sine.asin();
    assert_ordered(Ordered {
        low: 0.0,
        high: meters,
        label: "geodesy: a distance in meters",
    });
    meters
}

/// The initial great-circle bearing from `source` to `target`, in degrees
/// clockwise from true north, from 0 up to 360; 0 where the two are one
/// position.
#[must_use]
#[track_caller]
pub fn initial_bearing_degrees(between: Between) -> f64 {
    let Between { source, target } = between;
    let source_lat_radians = radians(source.lat);
    let target_lat_radians = radians(target.lat);
    let lon_delta = radians(target.lon - source.lon);
    let east = lon_delta.sin() * target_lat_radians.cos();
    let north_source = source_lat_radians.cos() * target_lat_radians.sin();
    let north_target = source_lat_radians.sin() * target_lat_radians.cos() * lon_delta.cos();
    let north = north_source - north_target;
    let bearing = degrees(east.atan2(north));
    normalized_degrees(bearing)
}

/// The meters of a degree of longitude at `latitude_degrees`.
///
/// Multiplying a longitude by it, and a latitude by `METERS_PER_DEGREE`, places
/// positions on a plane tangent at that latitude, which is meaningless across
/// the antimeridian.
#[must_use]
#[track_caller]
pub fn meters_per_degree_longitude(latitude_degrees: f64) -> f64 {
    assert::condition(latitude_degrees.abs() <= LATITUDE_DEGREES_MAX, || {
        format!(
            "geodesy: latitude {} is out of range",
            number_text(latitude_degrees)
        )
    });
    METERS_PER_DEGREE * radians(latitude_degrees).cos()
}

/// A plane tangent at `reference_latitude_degrees`, taken from the data it
/// measures, such as a path's first point or the center of a map's bounds,
/// with the meters of a degree of longitude on it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct TangentPlane {
    pub reference_latitude_degrees: f64,
    pub meters_per_degree_lon: f64,
}

/// The plane tangent at `reference_latitude_degrees`.
#[must_use]
#[track_caller]
pub fn tangent_plane(reference_latitude_degrees: f64) -> TangentPlane {
    let meters_per_degree_lon = meters_per_degree_longitude(reference_latitude_degrees);
    assert::condition(meters_per_degree_lon > 0.0, || {
        format!(
            "geodesy: a plane at {} has a scale of {}",
            number_text(reference_latitude_degrees),
            number_text(meters_per_degree_lon)
        )
    });
    TangentPlane {
        reference_latitude_degrees,
        meters_per_degree_lon,
    }
}

/// A plane and the span of latitudes it must measure.
#[derive(Debug, Clone, Copy)]
pub struct PlaneCoverage {
    pub plane: TangentPlane,
    pub latitude_degrees_min: f64,
    pub latitude_degrees_max: f64,
}

/// Asserts that `plane` measures every latitude of a span closely enough.
///
/// Every latitude from `latitude_degrees_min` to `latitude_degrees_max` is
/// within `PLANE_SCALE_ERROR_MAX`, so data that spans too much of the globe for
/// one plane fails here rather than drifting.
#[track_caller]
pub fn assert_plane_covers(coverage: PlaneCoverage) {
    let PlaneCoverage {
        plane,
        latitude_degrees_min,
        latitude_degrees_max,
    } = coverage;
    assert::condition(latitude_degrees_min <= latitude_degrees_max, || {
        format!(
            "geodesy: latitudes {} to {} are out of order",
            number_text(latitude_degrees_min),
            number_text(latitude_degrees_max)
        )
    });
    let south_error = scale_error(plane, latitude_degrees_min);
    let north_error = scale_error(plane, latitude_degrees_max);
    assert_scale_error_within(ScaleError {
        plane,
        latitude_degrees: latitude_degrees_min,
        error: south_error,
    });
    assert_scale_error_within(ScaleError {
        plane,
        latitude_degrees: latitude_degrees_max,
        error: north_error,
    });

    // A span across the equator is widest there, between its two ends.
    let is_south_end_below_equator = latitude_degrees_min < 0.0;
    let is_across_equator = is_south_end_below_equator && latitude_degrees_max > 0.0;
    if is_across_equator {
        let equator_error = scale_error(plane, 0.0);
        assert::condition(equator_error <= PLANE_SCALE_ERROR_MAX, || {
            format!(
                "geodesy: the plane at {} is {} off at the equator",
                number_text(plane.reference_latitude_degrees),
                number_text(equator_error)
            )
        });
    }
}

#[derive(Debug, Clone, Copy)]
struct ScaleError {
    plane: TangentPlane,
    latitude_degrees: f64,
    error: f64,
}

#[track_caller]
fn assert_scale_error_within(scale: ScaleError) {
    let ScaleError {
        plane,
        latitude_degrees,
        error,
    } = scale;
    assert::condition(error <= PLANE_SCALE_ERROR_MAX, || {
        format!(
            "geodesy: the plane at {} is {} off at {}",
            number_text(plane.reference_latitude_degrees),
            number_text(error),
            number_text(latitude_degrees)
        )
    });
}

#[track_caller]
fn scale_error(plane: TangentPlane, latitude_degrees: f64) -> f64 {
    let true_meters_per_degree_lon = meters_per_degree_longitude(latitude_degrees);
    (plane.meters_per_degree_lon / true_meters_per_degree_lon - 1.0).abs()
}
