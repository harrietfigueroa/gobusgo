// Checks the angles module against the shared cases: conversions of the
// quarter and half turns, the exact bits of a conversion that multiplies
// before it divides, the range normalized angles fall in, the smaller turn
// between two directions across north, and the refusal of an angle that is no
// number.

use gobusgo_core::math::angles::{
    DEGREES_PER_HALF_TURN, DEGREES_PER_TURN, Turn, degrees, normalized_degrees, radians,
    turn_degrees,
};

use crate::json::Value;
use crate::{assert_fails, fixture};

fn cases() -> Value {
    fixture(include_str!("../../../../test/fixtures/math/angles.json"))
}

#[test]
fn the_constants() {
    let constants = cases().get("constants").clone();
    assert_eq!(DEGREES_PER_TURN, constants.get("DEGREES_PER_TURN").number());
    assert_eq!(
        DEGREES_PER_HALF_TURN,
        constants.get("DEGREES_PER_HALF_TURN").number()
    );
}

#[test]
fn conversions_to_radians() {
    let cases = cases();
    let tolerance = cases.get("conversionTolerance").number();
    for case in cases.get("conversions").items() {
        let converted = radians(case.get("degrees").number());
        let error = (converted - case.get("radians").number()).abs();
        assert!(error <= tolerance, "case: {}", case.get("name").text());
    }
}

#[test]
fn conversions_to_degrees() {
    let cases = cases();
    let tolerance = cases.get("conversionTolerance").number();
    for case in cases.get("conversions").items() {
        let converted = degrees(case.get("radians").number());
        let error = (converted - case.get("degrees").number()).abs();
        assert!(error <= tolerance, "case: {}", case.get("name").text());
    }
}

#[test]
fn exact_conversions_to_radians() {
    for case in cases().get("exactRadians").items() {
        let converted = radians(case.get("degrees").number());
        assert_eq!(
            converted,
            case.get("radians").number(),
            "case: {}",
            case.get("name").text()
        );
    }
}

#[test]
fn normalized_angles() {
    for case in cases().get("normalized").items() {
        let normalized = normalized_degrees(case.get("degrees").number());
        assert_eq!(
            normalized,
            case.get("normalized").number(),
            "case: {}",
            case.get("name").text()
        );
    }
}

#[test]
fn turns() {
    for case in cases().get("turns").items() {
        let turn = turn_degrees(Turn {
            from: case.get("from").number(),
            to: case.get("to").number(),
        });
        assert_eq!(
            turn,
            case.get("turn").number(),
            "case: {}",
            case.get("name").text()
        );
    }
}

#[test]
fn refused_radians() {
    for case in cases().get("refusedRadians").items() {
        let value = case.get("degrees").number();
        assert_fails(|| radians(value));
    }
}

#[test]
fn refused_normalized_angles() {
    for case in cases().get("refusedNormalized").items() {
        let value = case.get("degrees").number();
        assert_fails(|| normalized_degrees(value));
    }
}
