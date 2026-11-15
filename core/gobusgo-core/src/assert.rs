//! The assertions of the core.
//!
//! A failed assertion is a programmer error and panics with an
//! `AssertionError` as its payload, never a value a caller handles. One payload
//! type for every assertion lets a binding tell an assertion's failure from any
//! other panic and hand its message across.

use std::fmt;

/// The payload every failed assertion panics with, carrying its message.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AssertionError {
    message: String,
}

impl AssertionError {
    /// The message the failed assertion wrote, with the operand values it found.
    #[must_use]
    pub fn message(&self) -> &str {
        &self.message
    }
}

impl fmt::Display for AssertionError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(&self.message)
    }
}

/// Panics with an `AssertionError` whose message `message` writes unless
/// `condition` holds. The message is written only on a failure, so the hot
/// paths pay for formatting their operands only when they fail.
#[track_caller]
pub fn condition<Message: FnOnce() -> String>(condition: bool, message: Message) {
    if condition {
        return;
    }

    fail(message());
}

/// Panics with an `AssertionError` naming `value`, a member no arm of a
/// dispatch handles.
#[track_caller]
pub fn unreachable(value: &dyn fmt::Display, message: &str) -> ! {
    fail(format!("{message}: {value}"));
}

#[track_caller]
fn fail(message: String) -> ! {
    // The one panic of the assertions, which carries the failure type rather
    // than a string, so every assertion fails through this line.
    #[expect(clippy::panic)]
    std::panic::panic_any(AssertionError { message });
}

// The largest decimal exponent a number is written out in full at, and the
// least written with a leading `0.`, by ECMAScript's Number::toString.
// https://tc39.es/ecma262/#sec-numeric-types-number-tostring — checked 2026-11-14
const FULL_EXPONENT_MAX: i32 = 20;
const FRACTION_EXPONENT_MIN: i32 = -6;

/// `value` as JavaScript's `String(value)` writes it.
///
/// The shortest digits that read back as `value`, in full from a millionth up
/// to 10^21 and with an exponent outside that range, `0` for either zero, and
/// `NaN`, `Infinity`, and `-Infinity`. A failure's message reads the same from
/// either core.
#[must_use]
pub fn number_text(value: f64) -> String {
    if value.is_nan() {
        return "NaN".to_owned();
    }

    if value.is_infinite() {
        if value.is_sign_positive() {
            return "Infinity".to_owned();
        }
        return "-Infinity".to_owned();
    }

    if value == 0.0 {
        return "0".to_owned();
    }

    let sign = if value.is_sign_negative() { "-" } else { "" };
    // Rust writes the shortest digits that read back as the value, as
    // JavaScript does, so only their layout differs.
    let scientific = format!("{:e}", value.abs());
    let Some((mantissa, exponent_text)) = scientific.split_once('e') else {
        unreachable(
            &scientific,
            "assert: a number in scientific notation holds an exponent",
        );
    };
    let digits: String = mantissa.chars().filter(char::is_ascii_digit).collect();
    let Ok(exponent) = exponent_text.parse::<i32>() else {
        unreachable(&scientific, "assert: a number's exponent is an integer");
    };

    let layout = laid_out(&digits, exponent);
    format!("{sign}{layout}")
}

// The digits `digits`, the first of them at the decimal exponent `exponent`,
// laid out as Number::toString lays them out.
fn laid_out(digits: &str, exponent: i32) -> String {
    let digit_count = digits.len();
    let Ok(last_exponent) = i32::try_from(digit_count) else {
        unreachable(
            &digit_count,
            "assert: a double has at most 17 significant digits",
        );
    };
    let is_full = (0..=FULL_EXPONENT_MAX).contains(&exponent);
    let is_fraction = (FRACTION_EXPONENT_MIN..0).contains(&exponent);

    if is_full {
        let integer_count = exponent.unsigned_abs().saturating_add(1);
        let Ok(integer_count) = usize::try_from(integer_count) else {
            unreachable(&integer_count, "assert: an integer part fits a usize");
        };
        if integer_count >= digit_count {
            let zeros = "0".repeat(integer_count.saturating_sub(digit_count));
            return format!("{digits}{zeros}");
        }
        let Some((integer, fraction)) = digits.split_at_checked(integer_count) else {
            unreachable(
                &integer_count,
                "assert: an integer part lies inside its digits",
            );
        };
        return format!("{integer}.{fraction}");
    }

    if is_fraction {
        let leading = exponent.unsigned_abs().saturating_sub(1);
        let Ok(leading) = usize::try_from(leading) else {
            unreachable(&leading, "assert: a fraction's leading zeros fit a usize");
        };
        let zeros = "0".repeat(leading);
        return format!("0.{zeros}{digits}");
    }

    let exponent_sign = if exponent < 0 { "-" } else { "+" };
    let magnitude = exponent.unsigned_abs();
    let mut characters = digits.chars();
    let Some(first) = characters.next() else {
        unreachable(&last_exponent, "assert: a nonzero number has a digit");
    };
    let rest: String = characters.collect();
    if rest.is_empty() {
        return format!("{first}e{exponent_sign}{magnitude}");
    }
    format!("{first}.{rest}e{exponent_sign}{magnitude}")
}
