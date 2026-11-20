// Checks the hot paths' assertions against the shared cases: finite numbers
// and ordered pairs pass, and each refusal raises the message the JavaScript
// core writes, with its numbers written as JavaScript writes them.

use gobusgo_core::math::checks::{Ordered, assert_finite, assert_ordered};

use crate::json::Value;
use crate::{failure_of, fixture};

fn cases() -> Value {
    fixture(include_str!("../../../../test/fixtures/math/checks.json"))
}

#[test]
fn a_finite_number_passes() {
    for case in cases().get("finite").items() {
        assert_finite(case.get("value").number(), "a finite number");
    }
}

#[test]
fn a_number_that_is_not_finite_is_refused() {
    for case in cases().get("refusedFinite").items() {
        let value = case.get("value").number();
        let label = case.get("label").text();
        let failure = failure_of(|| assert_finite(value, label));
        assert_eq!(
            failure.message(),
            case.get("failure").text(),
            "case: {}",
            case.get("name").text()
        );
    }
}

#[test]
fn an_ordered_pair_passes() {
    for case in cases().get("ordered").items() {
        assert_ordered(Ordered {
            low: case.get("low").number(),
            high: case.get("high").number(),
            label: "an ordered pair",
        });
    }
}

#[test]
fn a_pair_out_of_order_is_refused() {
    for case in cases().get("refusedOrdered").items() {
        let ordered = Ordered {
            low: case.get("low").number(),
            high: case.get("high").number(),
            label: case.get("label").text(),
        };
        let failure = failure_of(|| assert_ordered(ordered));
        assert_eq!(
            failure.message(),
            case.get("failure").text(),
            "case: {}",
            case.get("name").text()
        );
    }
}
