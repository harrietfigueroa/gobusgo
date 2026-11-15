//! Little-endian reads of a file's bytes, each `None` where the bytes end
//! before the value does, and the offset arithmetic of the readers, each an
//! assertion where a sum or a conversion cannot fit.

use crate::assert;

/// The `N` bytes at `offset`, or `None` where `bytes` ends before them.
fn array_at<const N: usize>(bytes: &[u8], offset: usize) -> Option<[u8; N]> {
    let end = offset.checked_add(N)?;
    let slice = bytes.get(offset..end)?;
    <[u8; N]>::try_from(slice).ok()
}

/// The byte at `offset`.
pub fn u8_at(bytes: &[u8], offset: usize) -> Option<u8> {
    bytes.get(offset).copied()
}

/// The unsigned 16-bit integer at `offset`.
pub fn u16_at(bytes: &[u8], offset: usize) -> Option<u16> {
    array_at(bytes, offset).map(u16::from_le_bytes)
}

/// The unsigned 32-bit integer at `offset`.
pub fn u32_at(bytes: &[u8], offset: usize) -> Option<u32> {
    array_at(bytes, offset).map(u32::from_le_bytes)
}

/// The signed 32-bit integer at `offset`.
pub fn i32_at(bytes: &[u8], offset: usize) -> Option<i32> {
    array_at(bytes, offset).map(i32::from_le_bytes)
}

/// The value a read inside a length the reader has checked found, which it
/// always finds.
#[track_caller]
pub fn checked<Value>(value: Option<Value>, offset: usize) -> Value {
    let Some(value) = value else {
        assert::unreachable(
            &offset,
            "bytes: a read inside a checked length ends inside it",
        );
    };
    value
}

/// `left + right`, an offset or length inside a file, which fits a `usize`.
#[track_caller]
pub fn sum(left: usize, right: usize) -> usize {
    let Some(total) = left.checked_add(right) else {
        assert::unreachable(&left, "bytes: an offset inside a file fits a usize");
    };
    total
}

/// `value` as a `usize`, which holds every `u32` on the targets the core builds for.
#[track_caller]
pub fn index_of(value: u32) -> usize {
    let Ok(index) = usize::try_from(value) else {
        assert::unreachable(&value, "bytes: a u32 fits a usize");
    };
    index
}

/// `value` as a double, exact for every length a file's bytes can have.
#[track_caller]
pub fn number_of(value: usize) -> f64 {
    let Ok(narrow) = u32::try_from(value) else {
        assert::unreachable(&value, "bytes: a length inside a file fits a u32");
    };
    f64::from(narrow)
}
