//! The conformance cases of the core, each module reading its table of cases
//! from the shared fixture it includes.

// The crate is test code throughout, and marking it so extends `clippy.toml`'s
// allowances inside tests to its helpers as well as its `#[test]` functions.
#![cfg(test)]

mod angles;
mod assert;
mod checks;
mod geodesy;
mod interpolation;
mod json;
mod packed_container;
mod routing_snapshot;
mod trip_path;

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

/// The bytes `hex` spells, two hexadecimal digits a byte.
fn hex_bytes(hex: &str) -> Vec<u8> {
    let digits = hex.as_bytes();
    assert!(
        digits.len().is_multiple_of(2),
        "hex: an odd count of digits in {hex}"
    );
    digits
        .chunks(2)
        .map(|pair| {
            let text = std::str::from_utf8(pair).unwrap();
            u8::from_str_radix(text, 16).unwrap()
        })
        .collect()
}

/// A copy of `bytes` with the shared refusal fixtures' `edits` applied in
/// order: `keep` keeps the first bytes, `cut` drops the last, `append` adds
/// the bytes its hexadecimal text spells, and `write` writes the bytes of
/// `hex` at `offset`.
fn edited_bytes(bytes: &[u8], edits: &json::Value) -> Vec<u8> {
    let mut edited = bytes.to_vec();
    for edit in edits.items() {
        if let Some(keep) = edit.member("keep") {
            edited.truncate(byte_count(keep));
        } else if let Some(cut) = edit.member("cut") {
            edited.truncate(edited.len().checked_sub(byte_count(cut)).unwrap());
        } else if let Some(append) = edit.member("append") {
            edited.extend(hex_bytes(append.text()));
        } else {
            let write = edit.get("write");
            let offset = byte_count(write.get("offset"));
            let written = hex_bytes(write.get("hex").text());
            edited[offset..offset.checked_add(written.len()).unwrap()].copy_from_slice(&written);
        }
    }
    edited
}

/// The count a fixture's number writes, which must be a whole count.
fn byte_count(value: &json::Value) -> usize {
    let number = value.number();
    assert!(number >= 0.0, "count: {number} is below zero");
    assert!(number.fract() == 0.0, "count: {number} is no whole number");
    format!("{number}").parse().unwrap()
}

/// Asserts that `operation` fails an assertion.
fn assert_fails<Operation, Returned>(operation: Operation)
where
    Operation: FnOnce() -> Returned + UnwindSafe,
{
    let _ = failure_of(operation);
}
