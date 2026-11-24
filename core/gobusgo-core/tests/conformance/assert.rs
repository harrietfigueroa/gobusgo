// Checks the core's assertions against the shared cases: a condition that
// holds passes, one that fails raises the AssertionError with the message it
// was given, and an unreachable arm names the value it found.

use gobusgo_core::assert::{self, number_text};

use crate::json::Value;
use crate::{failure_of, fixture};

fn cases() -> Value {
    fixture(include_str!("../../../../test/fixtures/math/assert.json"))
}

#[test]
fn a_held_condition_passes() {
    for case in cases().get("heldConditions").items() {
        let message = case.get("message").text().to_owned();
        assert::condition(true, || message);
    }
}

#[test]
fn a_failed_condition_raises_its_message() {
    for case in cases().get("failedConditions").items() {
        let message = case.get("message").text().to_owned();
        let expected = message.clone();
        let failure = failure_of(|| assert::condition(false, || message));
        assert_eq!(
            failure.message(),
            expected,
            "case: {}",
            case.get("name").text()
        );
    }
}

#[test]
fn an_unreachable_arm_names_its_value() {
    for case in cases().get("unreachables").items() {
        let value = match case.get("value") {
            Value::Text(text) => text.clone(),
            number => number_text(number.number()),
        };
        let message = case.get("message").text().to_owned();
        let failure = failure_of(|| assert::unreachable(&value, &message));
        assert_eq!(
            failure.message(),
            case.get("failure").text(),
            "case: {}",
            case.get("name").text()
        );
    }
}
