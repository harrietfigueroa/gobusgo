//! Reads the packed container of the published data files.
//!
//! Every data file of a kind added after the routing snapshot uses the
//! container, as `Gobusgo.Packed` writes it, and this is a port of
//! `assets/js/core/packed_container.js`: a 16-byte header, little-endian, of
//! the magic "GBPK", a u16 kind version, a u16 kind, a u32 record count, and a
//! u32 reserved, zero, then sections, each a u32 byte length and that many
//! bytes. Section 0 is the string table. A file is stored as one gzip stream,
//! and this module reads it once expanded. Everything here is pure, and a bad
//! file is a refusal, never a panic; an option that no caller can pass
//! correctly fails an assertion, as the JavaScript's does.
//!
//! The options take numbers as doubles, as the JavaScript compares them, so a
//! kind or a version no header can hold is refused as the JavaScript refuses it.

use crate::assert::{self, number_text};
use crate::bytes::{checked, i32_at, index_of, number_of, sum, u8_at, u16_at, u32_at};

const MAGIC: &[u8; 4] = b"GBPK";
const STRING_TABLE_SECTION_INDEX: usize = 0;
const VERSION_OFFSET: usize = 4;
const KIND_OFFSET: usize = 6;
const RECORD_COUNT_OFFSET: usize = 8;
const RESERVED_OFFSET: usize = 12;
const U32_BYTES: usize = 4;
const COORDINATE_COUNT: usize = 2;
const POSITION_BYTES: usize = 8;
const LATITUDE_MICRODEGREES_MAX: u64 = 90_000_000;
const LONGITUDE_MICRODEGREES_MAX: u64 = 180_000_000;
const VARINT_BASE: u8 = 128;
const VARINT_PAYLOAD_BITS: u32 = 7;
const ZIGZAG_DIVISOR: f64 = 2.0;
const FILE_SUFFIX: &str = ".bin.gz";

/// The bytes of a header.
pub const HEADER_BYTES: usize = 16;

/// The largest value a varint holds.
pub const VARINT_VALUE_MAX: u32 = u32::MAX;

/// The most bytes a varint takes.
pub const VARINT_BYTES_MAX: usize = 5;

/// The value of both axes of an unknown position.
pub const UNKNOWN_MICRODEGREES: i32 = i32::MIN;

/// The most bytes a stored container expands to, the bound the server stores
/// compressed content under.
pub const CONTAINER_EXPANDED_BYTES_MAX: usize = 16 * 1024 * 1024;

/// A kind of the table: its number, its name, and the file prefix of its stored files.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Kind {
    pub number: u16,
    /// The key the JavaScript's `PackedKind` holds the number under.
    pub key: &'static str,
    pub name: &'static str,
    pub prefix: &'static str,
}

/// The kind table, in the order of the numbers.
pub const KINDS: [Kind; 8] = [
    Kind {
        number: 0,
        key: "fixture",
        name: "fixture",
        prefix: "fixture",
    },
    Kind {
        number: 1,
        key: "tripPathShard",
        name: "trip path shard",
        prefix: "trip-paths",
    },
    Kind {
        number: 2,
        key: "tripPathIndex",
        name: "trip path index",
        prefix: "trip-paths-index",
    },
    Kind {
        number: 3,
        key: "addressShard",
        name: "address shard",
        prefix: "addresses",
    },
    Kind {
        number: 4,
        key: "addressIndex",
        name: "address index",
        prefix: "addresses-index",
    },
    Kind {
        number: 5,
        key: "places",
        name: "places",
        prefix: "places",
    },
    Kind {
        number: 6,
        key: "intersectionShard",
        name: "intersection shard",
        prefix: "intersections",
    },
    Kind {
        number: 7,
        key: "intersectionIndex",
        name: "intersection index",
        prefix: "intersections-index",
    },
];

/// The `kind` of every result, by the names the JavaScript's `PackedOutcome` gives them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Outcome {
    Expanded,
    Decoded,
    Refused,
}

impl Outcome {
    /// Every outcome, in the JavaScript's order.
    pub const ALL: [Self; 3] = [Self::Expanded, Self::Decoded, Self::Refused];

    /// The outcome's name, the `kind` a JavaScript result carries.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Expanded => "expanded",
            Self::Decoded => "decoded",
            Self::Refused => "refused",
        }
    }
}

/// Why a stream or a container was refused, by the names the JavaScript's
/// `PackedRefusal` gives them. `TooLarge` and `Corrupt` are a stream's, which a
/// platform's driver expands.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Refusal {
    TooLarge,
    Corrupt,
    BadMagic,
    UnknownKind,
    KindMismatch,
    UnsupportedVersion,
    ReservedNotZero,
    Truncated,
    TrailingBytes,
    SectionCount,
    BadVarint,
    BadUtf8,
    BadStringTable,
    BadSectionSize,
    BadPosition,
}

impl Refusal {
    /// Every reason, in the JavaScript's order.
    pub const ALL: [Self; 15] = [
        Self::TooLarge,
        Self::Corrupt,
        Self::BadMagic,
        Self::UnknownKind,
        Self::KindMismatch,
        Self::UnsupportedVersion,
        Self::ReservedNotZero,
        Self::Truncated,
        Self::TrailingBytes,
        Self::SectionCount,
        Self::BadVarint,
        Self::BadUtf8,
        Self::BadStringTable,
        Self::BadSectionSize,
        Self::BadPosition,
    ];

    /// The reason's name, the `reason` a JavaScript refusal carries.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::TooLarge => "tooLarge",
            Self::Corrupt => "corrupt",
            Self::BadMagic => "badMagic",
            Self::UnknownKind => "unknownKind",
            Self::KindMismatch => "kindMismatch",
            Self::UnsupportedVersion => "unsupportedVersion",
            Self::ReservedNotZero => "reservedNotZero",
            Self::Truncated => "truncated",
            Self::TrailingBytes => "trailingBytes",
            Self::SectionCount => "sectionCount",
            Self::BadVarint => "badVarint",
            Self::BadUtf8 => "badUtf8",
            Self::BadStringTable => "badStringTable",
            Self::BadSectionSize => "badSectionSize",
            Self::BadPosition => "badPosition",
        }
    }
}

/// The types of a fixed-width column, by the names the JavaScript's `ColumnType` gives them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ColumnType {
    U8,
    U16,
    U32,
    I32,
}

impl ColumnType {
    /// Every type, in the JavaScript's order.
    pub const ALL: [Self; 4] = [Self::U8, Self::U16, Self::U32, Self::I32];

    /// The type's name, as the JavaScript's `ColumnType` holds it.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::U8 => "u8",
            Self::U16 => "u16",
            Self::U32 => "u32",
            Self::I32 => "i32",
        }
    }

    /// The bytes of one value of the type.
    #[must_use]
    pub const fn byte_size(self) -> usize {
        match self {
            Self::U8 => 1,
            Self::U16 => 2,
            Self::U32 | Self::I32 => 4,
        }
    }
}

/// A container's header.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Header {
    pub kind: u16,
    pub version: u16,
    pub record_count: u32,
}

/// A run of a file's bytes: where it starts and how many bytes it holds.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Section {
    pub offset: usize,
    pub byte_length: usize,
}

impl Section {
    /// The bytes of `bytes` the section holds, which must lie inside them.
    #[must_use]
    pub fn of(self, bytes: &[u8]) -> &[u8] {
        let end = self.offset.checked_add(self.byte_length);
        let held = end.and_then(|section_end| bytes.get(self.offset..section_end));
        let Some(held) = held else {
            assert::unreachable(
                &format!("{}+{} of {}", self.offset, self.byte_length, bytes.len()),
                "packed: a section lies inside its bytes",
            );
        };
        held
    }
}

/// What a reader expects of a container: its kind, the versions it reads, and
/// the sections after the string table.
#[derive(Debug, Clone, Copy)]
pub struct ContainerOptions<'versions> {
    pub kind: f64,
    pub versions: &'versions [f64],
    pub section_count: f64,
}

/// A decoded container: its header, its string table with every entry checked
/// as UTF-8, and its sections after the string table, each over the bytes it
/// was decoded from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Container<'bytes> {
    pub header: Header,
    pub strings: Vec<&'bytes str>,
    pub sections: Vec<Section>,
}

/// A fixed-width column, by its type.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Column {
    U8(Vec<u8>),
    U16(Vec<u16>),
    U32(Vec<u32>),
    I32(Vec<i32>),
}

/// What `open_column` reads: a column of `count` values of `column_type`, the
/// whole of `section` of `bytes`.
#[derive(Debug, Clone, Copy)]
pub struct ColumnRequest<'bytes> {
    pub bytes: &'bytes [u8],
    pub section: Section,
    pub column_type: ColumnType,
    pub count: f64,
}

/// What `open_positions` reads: `count` positions, the whole of `section` of `bytes`.
#[derive(Debug, Clone, Copy)]
pub struct PositionsRequest<'bytes> {
    pub bytes: &'bytes [u8],
    pub section: Section,
    pub count: f64,
}

/// Positions in microdegrees by axis; an unknown position holds
/// `UNKNOWN_MICRODEGREES` on both.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Positions {
    pub latitude: Vec<i32>,
    pub longitude: Vec<i32>,
}

/// The name of a stored file: its kind's number and the lower case hexadecimal
/// SHA-256 of its gzip stream.
#[derive(Debug, Clone, Copy)]
pub struct FileNameOf<'hash> {
    pub kind: f64,
    pub sha256: &'hash str,
}

/// The name of the file of kind `kind` whose gzip stream has the SHA-256
/// `sha256`, as `Gobusgo.Packed.file_name/1` names it. The kind must be in the
/// table.
#[must_use]
pub fn packed_file_name(file: FileNameOf<'_>) -> String {
    let entry = KINDS
        .iter()
        .find(|candidate| is_same_number(f64::from(candidate.number), file.kind));
    assert::condition(entry.is_some(), || {
        "the kind must be in the table".to_owned()
    });
    let Some(entry) = entry else {
        assert::unreachable(
            &number_text(file.kind),
            "packed: a kind found in the table is in it",
        );
    };
    format!("{}-{}{FILE_SUFFIX}", entry.prefix, file.sha256)
}

/// The signed integer whose zigzag is `value`, an unsigned integer.
#[must_use]
pub fn unzigzag(value: f64) -> f64 {
    assert_safe_integer(value, "a zigzag value must be an integer");
    assert::condition(value >= 0.0, || {
        "a zigzag value must be unsigned".to_owned()
    });
    let is_even = value % ZIGZAG_DIVISOR == 0.0;

    if is_even {
        return value / ZIGZAG_DIVISOR;
    }

    -(value + 1.0) / ZIGZAG_DIVISOR
}

// The zigzag of a varint, as an integer: half an even value, and less than
// zero by half the next for an odd one.
fn unzigzag_varint(value: u32) -> i64 {
    let half = i64::from(value >> 1);

    if value & 1 == 0 {
        return half;
    }

    // `!half` is `-half - 1` in two's complement.
    !half
}

/// The largest integer a double holds exactly, with every integer below it.
const SAFE_INTEGER_MAX: f64 = 9_007_199_254_740_991.0;

fn is_safe_integer(value: f64) -> bool {
    let is_integer = value.fract() == 0.0;
    let is_in_range = value.abs() <= SAFE_INTEGER_MAX;
    is_integer && is_in_range
}

// Whether two numbers are equal as JavaScript's `===` compares them: zero
// equals negative zero, and NaN equals nothing.
#[expect(
    clippy::float_cmp,
    reason = "an option's number is compared exactly, as the JavaScript compares it"
)]
fn is_same_number(left: f64, right: f64) -> bool {
    left == right
}

fn is_integer(value: f64) -> bool {
    let is_finite = value.is_finite();
    is_finite && value.fract() == 0.0
}

#[track_caller]
fn assert_safe_integer(value: f64, message: &str) {
    assert::condition(is_safe_integer(value), || message.to_owned());
}

#[track_caller]
fn assert_count(count: f64) {
    assert_safe_integer(count, "the count must be an integer");
    assert::condition(count >= 0.0, || "the count must not be negative".to_owned());
}

/// Asserts that `index` indexes a run of `count` values; `name` names the run.
#[track_caller]
pub fn assert_index(index: f64, count: usize, name: &str) {
    assert::condition(is_integer(index), || {
        format!("the index into {name} must be an integer")
    });
    assert::condition(index >= 0.0, || {
        format!("the index into {name} must not be negative")
    });
    assert::condition(index < number_of(count), || {
        format!("the index into {name} must be under its count")
    });
}

const fn is_point_in_range(latitude: i64, longitude: i64) -> bool {
    let is_latitude_in_range = latitude.unsigned_abs() <= LATITUDE_MICRODEGREES_MAX;
    let is_longitude_in_range = longitude.unsigned_abs() <= LONGITUDE_MICRODEGREES_MAX;
    is_latitude_in_range && is_longitude_in_range
}

/// A reader of varints and paths over a section.
///
/// A read that finds a varint over-long, past 32 bits, or cut by the section's
/// end sets `refusal` to the reason and yields nothing; a caller checks
/// `refusal` after a run of reads.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SectionCursor<'bytes> {
    bytes: &'bytes [u8],
    /// The offset of the next byte the cursor reads, from the start of the bytes.
    pub offset: usize,
    end: usize,
    pub refusal: Option<Refusal>,
}

impl<'bytes> SectionCursor<'bytes> {
    /// A cursor at the start of `section` of `bytes`, which it must lie inside.
    #[must_use]
    pub fn new(bytes: &'bytes [u8], section: Section) -> Self {
        let _ = section.of(bytes);
        Self {
            bytes,
            offset: section.offset,
            end: sum(section.offset, section.byte_length),
            refusal: None,
        }
    }

    /// The bytes left in the section.
    #[must_use]
    pub fn remaining(&self) -> usize {
        let Some(remaining) = self.end.checked_sub(self.offset) else {
            assert::unreachable(&self.offset, "packed: a cursor lies inside its section");
        };
        remaining
    }

    /// The unsigned varint at the cursor, which then moves past it, or 0 with
    /// `refusal` set.
    pub fn read_varint(&mut self) -> u32 {
        let mut value: u64 = 0;
        let mut shift: u32 = 0;

        for _ in 0..VARINT_BYTES_MAX {
            if self.offset >= self.end {
                self.refusal = Some(Refusal::Truncated);
                return 0;
            }

            let byte = checked(u8_at(self.bytes, self.offset), self.offset);
            self.offset = sum(self.offset, 1);
            value = with_payload(value, byte % VARINT_BASE, shift);
            shift = sum_bits(shift);

            let Ok(narrow) = u32::try_from(value) else {
                self.refusal = Some(Refusal::BadVarint);
                return 0;
            };

            if byte < VARINT_BASE {
                return narrow;
            }
        }

        self.refusal = Some(Refusal::BadVarint);
        0
    }

    /// The path at the cursor: a varint count of points, then per point the
    /// zigzag varint deltas of latitude and longitude from the point before,
    /// the first from (0, 0). Returns latitude and longitude microdegrees in
    /// turn, two per point, with the cursor past the path. A count the section
    /// cannot hold, at two bytes a point, is refused before anything is
    /// allocated; a refused path sets `refusal` and returns no point.
    pub fn read_path(&mut self) -> Vec<i32> {
        let count = self.read_varint();

        if self.refusal.is_some() {
            return Vec::new();
        }

        let values_needed = index_of(count).checked_mul(COORDINATE_COUNT);
        let fits = values_needed.filter(|needed| *needed <= self.remaining());
        let Some(values_needed) = fits else {
            self.refusal = Some(Refusal::Truncated);
            return Vec::new();
        };

        let mut points = Vec::with_capacity(values_needed);
        let mut latitude: i64 = 0;
        let mut longitude: i64 = 0;

        for _ in 0..count {
            latitude = step(latitude, unzigzag_varint(self.read_varint()));
            longitude = step(longitude, unzigzag_varint(self.read_varint()));

            if self.refusal.is_some() {
                return Vec::new();
            }

            if !is_point_in_range(latitude, longitude) {
                self.refusal = Some(Refusal::BadPosition);
                return Vec::new();
            }

            points.push(microdegrees_of(latitude));
            points.push(microdegrees_of(longitude));
        }

        points
    }
}

// `value` with a varint byte's payload added at `shift`; five bytes' payloads
// take 35 bits, which a u64 holds.
#[track_caller]
fn with_payload(value: u64, payload: u8, shift: u32) -> u64 {
    let part = u64::from(payload).checked_shl(shift);
    let Some(next) = part.and_then(|shifted| value.checked_add(shifted)) else {
        assert::unreachable(&shift, "packed: a varint's payloads fit a u64");
    };
    next
}

// The next shift of a varint's payload, at most its five bytes' 35 bits.
#[track_caller]
fn sum_bits(shift: u32) -> u32 {
    let Some(next) = shift.checked_add(VARINT_PAYLOAD_BITS) else {
        assert::unreachable(&shift, "packed: a varint's shift fits a u32");
    };
    next
}

// A coordinate in range, which fits an i32.
#[track_caller]
fn microdegrees_of(coordinate: i64) -> i32 {
    let Ok(microdegrees) = i32::try_from(coordinate) else {
        assert::unreachable(&coordinate, "packed: a coordinate in range fits an i32");
    };
    microdegrees
}

// A coordinate moved by a delta; a path's points are at most one per two of
// its bytes, so the sum of their deltas fits an i64.
#[track_caller]
fn step(coordinate: i64, delta: i64) -> i64 {
    let Some(next) = coordinate.checked_add(delta) else {
        assert::unreachable(&coordinate, "packed: a path's coordinate fits an i64");
    };
    next
}

// A refusal where `section` does not hold `count` values of `byte_size` bytes.
fn check_section_size(section: Section, byte_size: usize, count: f64) -> Result<(), Refusal> {
    assert_count(count);
    let byte_length = number_of(section.byte_length);

    // A double product, as the JavaScript computes it.
    let fits = is_same_number(byte_length, count * number_of(byte_size));

    if !fits {
        return Err(Refusal::BadSectionSize);
    }

    Ok(())
}

/// The fixed-width column a section holds.
///
/// # Errors
///
/// `BadSectionSize` where the section is not `count` values long.
pub fn open_column(request: ColumnRequest<'_>) -> Result<Column, Refusal> {
    let ColumnRequest {
        bytes,
        section,
        column_type,
        count,
    } = request;
    let held = section.of(bytes);
    check_section_size(section, column_type.byte_size(), count)?;
    let values = held.chunks_exact(column_type.byte_size());
    let column = match column_type {
        ColumnType::U8 => Column::U8(held.to_vec()),
        ColumnType::U16 => Column::U16(values.map(|value| checked(u16_at(value, 0), 0)).collect()),
        ColumnType::U32 => Column::U32(values.map(|value| checked(u32_at(value, 0), 0)).collect()),
        ColumnType::I32 => Column::I32(values.map(|value| checked(i32_at(value, 0), 0)).collect()),
    };
    Ok(column)
}

fn is_position_refused(latitude: i32, longitude: i32) -> bool {
    let is_unknown_latitude = latitude == UNKNOWN_MICRODEGREES;
    let is_unknown_longitude = longitude == UNKNOWN_MICRODEGREES;

    if is_unknown_latitude != is_unknown_longitude {
        return true;
    }

    let is_unknown = is_unknown_latitude && is_unknown_longitude;
    let is_in_range = is_point_in_range(i64::from(latitude), i64::from(longitude));
    !is_unknown && !is_in_range
}

/// The positions a section holds, each two i32 of microdegrees, latitude then longitude.
///
/// # Errors
///
/// `BadSectionSize` for a section not `count` positions long, and
/// `BadPosition` for a position out of range or unknown on one axis alone.
pub fn open_positions(request: PositionsRequest<'_>) -> Result<Positions, Refusal> {
    let PositionsRequest {
        bytes,
        section,
        count,
    } = request;
    let held = section.of(bytes);
    check_section_size(section, POSITION_BYTES, count)?;
    let (records, _) = held.as_chunks::<POSITION_BYTES>();
    let mut positions = Positions {
        latitude: Vec::with_capacity(records.len()),
        longitude: Vec::with_capacity(records.len()),
    };

    for &[lat0, lat1, lat2, lat3, lon0, lon1, lon2, lon3] in records {
        let latitude = i32::from_le_bytes([lat0, lat1, lat2, lat3]);
        let longitude = i32::from_le_bytes([lon0, lon1, lon2, lon3]);

        if is_position_refused(latitude, longitude) {
            return Err(Refusal::BadPosition);
        }

        positions.latitude.push(latitude);
        positions.longitude.push(longitude);
    }

    Ok(positions)
}

// The string table of `section`: each entry checked as UTF-8.
fn read_string_table(bytes: &[u8], section: Section) -> Result<Vec<&str>, Refusal> {
    if section.byte_length < U32_BYTES {
        return Err(Refusal::Truncated);
    }

    let count = index_of(checked(u32_at(bytes, section.offset), section.offset));
    let entries = Section {
        offset: sum(section.offset, U32_BYTES),
        byte_length: section.byte_length.saturating_sub(U32_BYTES),
    };
    let mut cursor = SectionCursor::new(bytes, entries);

    // Each entry takes at least one byte, so a larger count is cut short.
    if count > cursor.remaining() {
        return Err(Refusal::Truncated);
    }

    let mut strings = Vec::with_capacity(count);

    for _ in 0..count {
        let length = index_of(cursor.read_varint());

        if let Some(refusal) = cursor.refusal {
            return Err(refusal);
        }

        if length > cursor.remaining() {
            return Err(Refusal::Truncated);
        }

        let entry = Section {
            offset: cursor.offset,
            byte_length: length,
        }
        .of(bytes);
        let Ok(text) = std::str::from_utf8(entry) else {
            return Err(Refusal::BadUtf8);
        };
        strings.push(text);
        cursor.offset = sum(cursor.offset, length);
    }

    if cursor.remaining() != 0 {
        return Err(Refusal::BadStringTable);
    }

    Ok(strings)
}

fn is_known_kind(number: u16) -> bool {
    KINDS.iter().any(|entry| entry.number == number)
}

// The header of `bytes`, or the reason it is refused.
fn read_header(bytes: &[u8]) -> Result<Header, Refusal> {
    let has_magic_bytes = bytes.len() >= MAGIC.len();

    if has_magic_bytes {
        if !bytes.starts_with(MAGIC) {
            return Err(Refusal::BadMagic);
        }
    }

    if bytes.len() < HEADER_BYTES {
        return Err(Refusal::Truncated);
    }

    let kind = checked(u16_at(bytes, KIND_OFFSET), KIND_OFFSET);

    if !is_known_kind(kind) {
        return Err(Refusal::UnknownKind);
    }

    if checked(u32_at(bytes, RESERVED_OFFSET), RESERVED_OFFSET) != 0 {
        return Err(Refusal::ReservedNotZero);
    }

    Ok(Header {
        kind,
        version: checked(u16_at(bytes, VERSION_OFFSET), VERSION_OFFSET),
        record_count: checked(u32_at(bytes, RECORD_COUNT_OFFSET), RECORD_COUNT_OFFSET),
    })
}

// The sections of `bytes` after the header, or the reason they are refused.
// Each section takes at least its length's bytes, so the loop ends within the
// file's bytes.
fn read_sections(bytes: &[u8]) -> Result<Vec<Section>, Refusal> {
    let mut sections = Vec::new();
    let mut offset = HEADER_BYTES;

    while offset < bytes.len() {
        let Some(byte_length) = u32_at(bytes, offset) else {
            return Err(Refusal::TrailingBytes);
        };
        offset = sum(offset, U32_BYTES);
        let byte_length = index_of(byte_length);

        if byte_length > bytes.len().saturating_sub(offset) {
            return Err(Refusal::Truncated);
        }

        sections.push(Section {
            offset,
            byte_length,
        });
        offset = sum(offset, byte_length);
    }

    Ok(sections)
}

/// The container `bytes` holds, whose header names kind `options.kind`, one
/// of `options.versions`, and `options.section_count` sections after the
/// string table. Every string table entry is checked as UTF-8 here.
///
/// # Errors
///
/// The reason the container is refused: `BadMagic`, `UnknownKind`,
/// `KindMismatch`, `UnsupportedVersion`, `ReservedNotZero`, `Truncated`,
/// `TrailingBytes`, `SectionCount`, `BadVarint`, `BadUtf8`, or `BadStringTable`.
pub fn decode_container<'bytes>(
    bytes: &'bytes [u8],
    options: ContainerOptions<'_>,
) -> Result<Container<'bytes>, Refusal> {
    let ContainerOptions {
        kind,
        versions,
        section_count,
    } = options;
    assert::condition(is_integer(kind), || {
        "the kind must be an integer".to_owned()
    });
    assert::condition(is_integer(section_count), || {
        "the section count must be an integer".to_owned()
    });
    assert::condition(section_count >= 0.0, || {
        "the section count must not be negative".to_owned()
    });

    let header = read_header(bytes)?;

    if !is_same_number(f64::from(header.kind), kind) {
        return Err(Refusal::KindMismatch);
    }

    let version = f64::from(header.version);

    if !versions.contains(&version) {
        return Err(Refusal::UnsupportedVersion);
    }

    let mut sections = read_sections(bytes)?;
    let expected_sections = section_count + 1.0;

    let is_section_count = is_same_number(number_of(sections.len()), expected_sections);

    if !is_section_count {
        return Err(Refusal::SectionCount);
    }

    let table = sections.remove(STRING_TABLE_SECTION_INDEX);
    let strings = read_string_table(bytes, table)?;
    Ok(Container {
        header,
        strings,
        sections,
    })
}
