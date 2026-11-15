//! Linear interpolation and clamping of plain numbers. Everything here is pure.

use super::checks::{Ordered, assert_finite, assert_ordered};

/// A line from `from` to `to`, and the share of the way along it to go.
#[derive(Debug, Clone, Copy)]
pub struct Lerp {
    pub from: f64,
    pub to: f64,
    pub fraction: f64,
}

/// The value `fraction` of the way from `from` to `to`: `from` at 0, `to` at 1,
/// and on the same line outside them.
#[must_use]
#[track_caller]
pub fn lerp(line: Lerp) -> f64 {
    let Lerp { from, to, fraction } = line;
    assert_finite(fraction, "interpolation: a fraction");
    // A fused multiply-add rounds once where JavaScript rounds twice, so the
    // sum is written out to give the JavaScript core's bits.
    #[expect(clippy::suboptimal_flops)]
    let value = from + (to - from) * fraction;
    value
}

/// A value and the bounds to bring it inside, both included.
#[derive(Debug, Clone, Copy)]
pub struct Clamp {
    pub value: f64,
    pub min: f64,
    pub max: f64,
}

/// `value` brought inside `min` and `max`, both included. A value that is no
/// number stays no number and fails the check of the clamped value.
#[must_use]
#[track_caller]
pub fn clamp(clamp: Clamp) -> f64 {
    let Clamp { value, min, max } = clamp;
    assert_ordered(Ordered {
        low: min,
        high: max,
        label: "interpolation: a clamp's bounds",
    });
    // Comparisons keep a value that is no number, as JavaScript's `Math.max`
    // and `Math.min` do, where `f64::max` and `f64::min` pass over it.
    let clamped = if value < min {
        min
    } else if value > max {
        max
    } else {
        value
    };
    assert_ordered(Ordered {
        low: min,
        high: clamped,
        label: "interpolation: a clamped value",
    });
    clamped
}
