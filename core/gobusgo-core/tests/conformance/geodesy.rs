// Checks the geodesy module against the shared cases, values known by
// construction on the sphere of the mean radius: a degree of a meridian, a
// quarter of the equator, a degree across the antimeridian, and the bearings
// of the four compass directions, and the bearing of a published example. It
// checks the tangent plane's scale bound over a city's span and past it, and
// that a position the module refuses is refused.

use std::f64::consts::PI;

use gobusgo_core::math::geodesy::{
    Between, EARTH_RADIUS_METERS, METERS_PER_DEGREE, PlaneCoverage, Position, assert_plane_covers,
    assert_position, distance_meters, initial_bearing_degrees, meters_per_degree_longitude,
    tangent_plane,
};

use crate::json::Value;
use crate::{assert_fails, fixture};

const HALVES_PER_WHOLE: f64 = 2.0;

fn cases() -> Value {
    fixture(include_str!("../../../../test/fixtures/math/geodesy.json"))
}

fn position_of(coordinates: &Value) -> Position {
    let numbers = coordinates.numbers();
    let &[lon, lat] = numbers.as_slice() else {
        panic!("geodesy test: a position of {} coordinates", numbers.len());
    };
    Position { lon, lat }
}

fn place(cases: &Value, name: &Value) -> Position {
    position_of(cases.get("places").get(name.text()))
}

fn between(cases: &Value, case: &Value) -> Between {
    Between {
        source: place(cases, case.get("source")),
        target: place(cases, case.get("target")),
    }
}

// The meters a distance case expects, from the module's own radius.
fn expected_meters(kind: &str) -> f64 {
    let half_equator_meters = PI * EARTH_RADIUS_METERS;
    match kind {
        "none" => 0.0,
        "degree" => METERS_PER_DEGREE,
        "quarter" => half_equator_meters / HALVES_PER_WHOLE,
        "half" => half_equator_meters,
        _ => panic!("geodesy test: no distance kind {kind}"),
    }
}

#[test]
fn distances() {
    let cases = cases();
    let tolerance = cases.get("toleranceMeters").number();
    for case in cases.get("distances").items() {
        let meters = distance_meters(between(&cases, case));
        let error = (meters - expected_meters(case.get("kind").text())).abs();
        assert!(error <= tolerance, "case: {}", case.get("name").text());
    }
}

#[test]
fn distances_are_the_same_either_way() {
    let cases = cases();
    for case in cases.get("symmetricDistances").items() {
        let forward = between(&cases, case);
        let backward = Between {
            source: forward.target,
            target: forward.source,
        };
        assert_eq!(
            distance_meters(forward),
            distance_meters(backward),
            "case: {}",
            case.get("name").text()
        );
    }
}

#[test]
fn degrees_of_longitude() {
    let cases = cases();
    let tolerance = cases.get("toleranceMeters").number();
    for case in cases.get("longitudeDegrees").items() {
        let meters = meters_per_degree_longitude(case.get("latitudeDegrees").number());
        let expected = METERS_PER_DEGREE * case.get("share").number();
        assert!(
            (meters - expected).abs() <= tolerance,
            "case: {}",
            case.get("name").text()
        );
    }
}

#[test]
fn bearings() {
    let cases = cases();
    let tolerance = cases.get("toleranceDegrees").number();
    for case in cases.get("bearings").items() {
        let bearing = initial_bearing_degrees(between(&cases, case));
        let error = (bearing - case.get("degrees").number()).abs();
        assert!(error <= tolerance, "case: {}", case.get("name").text());
    }
}

#[test]
fn bearings_to_the_degree() {
    let cases = cases();
    for case in cases.get("roundedBearings").items() {
        let bearing = initial_bearing_degrees(between(&cases, case));
        assert_eq!(
            bearing.round(),
            case.get("degrees").number(),
            "case: {}",
            case.get("name").text()
        );
    }
}

#[test]
fn bearings_in_a_range() {
    let cases = cases();
    for case in cases.get("bearingRanges").items() {
        let bearing = initial_bearing_degrees(between(&cases, case));
        assert!(
            bearing > case.get("above").number(),
            "case: {}",
            case.get("name").text()
        );
        assert!(
            bearing < case.get("below").number(),
            "case: {}",
            case.get("name").text()
        );
    }
}

#[test]
fn refused_positions() {
    for case in cases().get("refusedPositions").items() {
        let coordinates = case.get("position").numbers();
        let label = case.get("name").text();
        assert_fails(|| assert_position(&coordinates, label));
    }
}

#[test]
fn planes() {
    for case in cases().get("planes").items() {
        let reference = case.get("referenceLatitudeDegrees").number();
        let plane = tangent_plane(reference);
        assert_eq!(
            plane.meters_per_degree_lon,
            meters_per_degree_longitude(reference),
            "case: {}",
            case.get("name").text()
        );
    }
}

fn coverage_of(case: &Value) -> PlaneCoverage {
    PlaneCoverage {
        plane: tangent_plane(case.get("referenceLatitudeDegrees").number()),
        latitude_degrees_min: case.get("latitudeDegreesMin").number(),
        latitude_degrees_max: case.get("latitudeDegreesMax").number(),
    }
}

#[test]
fn covered_spans() {
    for case in cases().get("coveredSpans").items() {
        assert_plane_covers(coverage_of(case));
    }
}

#[test]
fn refused_spans() {
    for case in cases().get("refusedSpans").items() {
        let coverage = coverage_of(case);
        assert_fails(|| assert_plane_covers(coverage));
    }
}

#[test]
fn refused_distances() {
    for case in cases().get("refusedDistances").items() {
        let refused = Between {
            source: position_of(case.get("source")),
            target: position_of(case.get("target")),
        };
        assert_fails(|| distance_meters(refused));
    }
}

#[test]
fn refused_degrees_of_longitude() {
    for case in cases().get("refusedLongitudeDegrees").items() {
        let latitude = case.get("latitudeDegrees").number();
        assert_fails(|| meters_per_degree_longitude(latitude));
    }
}
