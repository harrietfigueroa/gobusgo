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
    let raised = larger(min, value);
    let clamped = smaller(max, raised);
    assert_ordered(Ordered {
        low: min,
        high: clamped,
        label: "interpolation: a clamped value",
    });
    clamped
}

// The larger of `first` and `second` as JavaScript's `Math.max` takes it: a
// value that is no number wins, where `f64::max` passes over it, and +0 is
// above -0.
fn larger(first: f64, second: f64) -> f64 {
    if first.is_nan() {
        return first;
    }
    if second.is_nan() {
        return second;
    }
    if first > second {
        return first;
    }
    if second > first {
        return second;
    }
    if first.is_sign_positive() {
        return first;
    }
    second
}

// The smaller of `first` and `second` as JavaScript's `Math.min` takes it: a
// value that is no number wins, and -0 is below +0.
fn smaller(first: f64, second: f64) -> f64 {
    if first.is_nan() {
        return first;
    }
    if second.is_nan() {
        return second;
    }
    if first < second {
        return first;
    }
    if second < first {
        return second;
    }
    if first.is_sign_negative() {
        return first;
    }
    second
}
