//! The assertions of the math modules' hot paths. Each writes its message only
//! when it fails, since formatting a number costs more than the arithmetic it
//! guards.

use crate::assert::{self, number_text};

/// Asserts that `value` is a finite number; `label` names it in a failure.
#[track_caller]
pub fn assert_finite(value: f64, label: &str) {
    assert::condition(value.is_finite(), || {
        format!("{label}: {} is not a finite number", number_text(value))
    });
}

/// A pair of numbers that must be in order, and the label that names them.
#[derive(Debug, Clone, Copy)]
pub struct Ordered<'label> {
    pub low: f64,
    pub high: f64,
    pub label: &'label str,
}

/// Asserts that `low` is at most `high`; `label` names the pair in a failure,
/// and a pair holding no number is out of order.
#[track_caller]
pub fn assert_ordered(ordered: Ordered<'_>) {
    let Ordered { low, high, label } = ordered;
    assert::condition(low <= high, || {
        format!(
            "{label}: {} is above {}",
            number_text(low),
            number_text(high)
        )
    });
}
