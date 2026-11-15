// Checks the interpolation module against the shared cases: the two ends and
// the middle of a line, a fraction past the end, a clamp below, inside, and
// above its bounds, and the refusal of bounds out of order and of a value or
// fraction that is no number.

use gobusgo_core::math::interpolation::{Clamp, Lerp, clamp, lerp};

use crate::json::Value;
use crate::{assert_fails, fixture};

fn cases() -> Value {
    fixture(include_str!(
        "../../../../test/fixtures/math/interpolation.json"
    ))
}

fn line_of(case: &Value) -> Lerp {
    Lerp {
        from: case.get("from").number(),
        to: case.get("to").number(),
        fraction: case.get("fraction").number(),
    }
}

fn clamp_of(case: &Value) -> Clamp {
    Clamp {
        value: case.get("value").number(),
        min: case.get("min").number(),
        max: case.get("max").number(),
    }
}

#[test]
fn lerps() {
    for case in cases().get("lerps").items() {
        let value = lerp(line_of(case));
        // Bits rather than `==`, which takes -0 for +0.
        assert_eq!(
            value.to_bits(),
            case.get("value").number().to_bits(),
            "case: {}",
            case.get("name").text()
        );
    }
}

#[test]
fn clamps() {
    for case in cases().get("clamps").items() {
        let clamped = clamp(clamp_of(case));
        assert_eq!(
            clamped.to_bits(),
            case.get("clamped").number().to_bits(),
            "case: {}",
            case.get("name").text()
        );
    }
}

#[test]
fn refused_lerps() {
    for case in cases().get("refusedLerps").items() {
        let line = line_of(case);
        assert_fails(|| lerp(line));
    }
}

#[test]
fn refused_clamps() {
    for case in cases().get("refusedClamps").items() {
        let bounds = clamp_of(case);
        assert_fails(|| clamp(bounds));
    }
}
