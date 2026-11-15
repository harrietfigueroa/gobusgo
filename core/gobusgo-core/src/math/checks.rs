//! The assertions of the math modules' hot paths. Each writes its message only
//! when it fails, since formatting a number costs more than the arithmetic it
//! guards.

use crate::assert::{self, number_text};

/// Asserts that `value` is a finite number; `label` names it in a failure.
#[track_caller]
pub fn assert_finite(value: f64, label: &str) {
    assert::condition(value.is_finite(), || {
        not_finite_message(label, &number_text(value))
    });
}

/// The message of `assert_finite`'s failure for the value `value_text` writes,
/// for a binding that refuses a value of its platform no number.
#[must_use]
pub fn not_finite_message(label: &str, value_text: &str) -> String {
    format!("{label}: {value_text} is not a finite number")
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
