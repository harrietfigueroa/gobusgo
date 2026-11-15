//! Conversions between degrees and radians, and the arithmetic of compass
//! angles in degrees clockwise from north. Everything here is pure.
//!
//! A conversion multiplies by π before it divides by 180, as the JavaScript
//! core does. `f64::to_radians` multiplies by a precomputed π / 180, which
//! rounds once more and gives other bits for about a quarter of the latitudes.

use std::f64::consts::PI;

use super::checks::{Ordered, assert_finite, assert_ordered};

/// The degrees of a whole turn.
pub const DEGREES_PER_TURN: f64 = 360.0;

/// The degrees of a half turn, which is π radians.
pub const DEGREES_PER_HALF_TURN: f64 = 180.0;

/// `degrees` in radians.
#[must_use]
#[track_caller]
pub fn radians(degrees: f64) -> f64 {
    assert_finite(degrees, "angles: degrees");
    // The module header says why this is no `to_radians`.
    #[expect(clippy::suboptimal_flops)]
    let radians = degrees * PI / DEGREES_PER_HALF_TURN;
    radians
}

/// `radians` in degrees.
#[must_use]
#[track_caller]
pub fn degrees(radians: f64) -> f64 {
    assert_finite(radians, "angles: radians");
    // The module header says why this is no `to_degrees`.
    #[expect(clippy::suboptimal_flops)]
    let degrees = radians * DEGREES_PER_HALF_TURN / PI;
    degrees
}

/// `degrees` turned into the range from 0 up to, and not including, 360.
#[must_use]
#[track_caller]
pub fn normalized_degrees(degrees: f64) -> f64 {
    assert_finite(degrees, "angles: degrees");
    // `%` on doubles is the truncated remainder, as JavaScript's is.
    let remainder = degrees % DEGREES_PER_TURN;
    let normalized = (remainder + DEGREES_PER_TURN) % DEGREES_PER_TURN;
    assert_ordered(Ordered {
        low: 0.0,
        high: normalized,
        label: "angles: a normalized angle",
    });
    normalized
}

/// Two compass directions in degrees, the one turned from and the one turned to.
#[derive(Debug, Clone, Copy)]
pub struct Turn {
    pub from: f64,
    pub to: f64,
}

/// The smaller angle between the directions `from` and `to`, from 0 to 180
/// degrees, either way round.
#[must_use]
#[track_caller]
pub fn turn_degrees(turn: Turn) -> f64 {
    let Turn { from, to } = turn;
    let clockwise = normalized_degrees(to - from);
    let counterclockwise = DEGREES_PER_TURN - clockwise;
    if clockwise <= counterclockwise {
        return clockwise;
    }
    counterclockwise
}
