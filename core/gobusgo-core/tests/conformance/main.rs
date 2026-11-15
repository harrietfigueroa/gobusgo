//! The conformance cases of the core's math and assertions, each module reading
//! its table of cases from the shared fixture it includes.

// The crate is test code throughout, and marking it so extends `clippy.toml`'s
// allowances inside tests to its helpers as well as its `#[test]` functions.
#![cfg(test)]

mod angles;
mod assert;
mod checks;
mod geodesy;
mod interpolation;
mod json;

use std::panic::{self, UnwindSafe};
use std::sync::Once;

use gobusgo_core::assert::AssertionError;

static QUIET_HOOK: Once = Once::new();

/// The value of a fixture's JSON `text`.
fn fixture(text: &str) -> json::Value {
    json::parse(text)
}

/// The `AssertionError` `operation` fails with, which it must fail with rather
/// than return or panic otherwise.
fn failure_of<Operation, Returned>(operation: Operation) -> AssertionError
where
    Operation: FnOnce() -> Returned + UnwindSafe,
{
    // An expected failure prints nothing, and any other panic prints as it
    // would.
    QUIET_HOOK.call_once(|| {
        let default_hook = panic::take_hook();
        panic::set_hook(Box::new(move |info| {
            if info.payload().downcast_ref::<AssertionError>().is_none() {
                default_hook(info);
            }
        }));
    });
    let outcome = panic::catch_unwind(operation);
    let Err(payload) = outcome else {
        panic!("the operation returned rather than failing an assertion");
    };
    let Ok(failure) = payload.downcast::<AssertionError>() else {
        panic!("the operation panicked with no AssertionError");
    };
    *failure
}

/// Asserts that `operation` fails an assertion.
fn assert_fails<Operation, Returned>(operation: Operation)
where
    Operation: FnOnce() -> Returned + UnwindSafe,
{
    let _ = failure_of(operation);
}
