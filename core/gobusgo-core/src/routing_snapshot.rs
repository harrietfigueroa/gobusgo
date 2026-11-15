//! Reads the packed files of a routing snapshot, format version 2.
//!
//! The files are those `Gobusgo.Routing.SnapshotFormat` writes, and this is a
//! port of `assets/js/core/routing_snapshot.js`. Everything here is pure: each function
//! takes a file's bytes and returns its records, the connections, transfers,
//! and positions as columns a connection scan reads by index, or the reason the
//! file was refused. Every number is little-endian.

use crate::bytes::{checked, i32_at, index_of, sum, u8_at, u16_at, u32_at};

const FORMAT_MAGIC: &[u8; 4] = b"GBRT";
const HEADER_BYTES: usize = 16;
const VERSION_OFFSET: usize = 4;
const KIND_OFFSET: usize = 6;
const COUNT_OFFSET: usize = 8;
const STRING_LENGTH_BYTES: usize = 2;
const SERVICE_DAY_OFFSET_BYTES: usize = 1;

const TRANSFER_BYTES: usize = 12;
const TRANSFER_TO_STOP_OFFSET: usize = 4;
const TRANSFER_DURATION_OFFSET: usize = 8;

const CONNECTION_BYTES: usize = 24;
const CONNECTION_ARRIVAL_OFFSET: usize = 4;
const CONNECTION_DEPARTURE_STOP_OFFSET: usize = 8;
const CONNECTION_ARRIVAL_STOP_OFFSET: usize = 12;
const CONNECTION_TRIP_OFFSET: usize = 16;
const CONNECTION_SEQUENCE_OFFSET: usize = 20;
const CONNECTION_FLAGS_OFFSET: usize = 22;
const BOARDING_BIT: u8 = 1;
const ALIGHTING_BIT: u8 = 2;

const POSITION_BYTES: usize = 8;
const POSITION_LON_OFFSET: usize = 4;
const LAT_MICRODEGREES_MAX: u32 = 90_000_000;
const LON_MICRODEGREES_MAX: u32 = 180_000_000;

// A leading byte order mark, which the JavaScript's `TextDecoder` drops from
// each string it decodes, as the WHATWG Encoding standard's UTF-8 decode does.
// https://encoding.spec.whatwg.org/#utf-8-decode — checked 2026-11-14
const BYTE_ORDER_MARK: char = '\u{feff}';

/// The format version this module reads, as the manifest's `formatVersion` names it.
pub const FORMAT_VERSION: u16 = 2;

/// The microdegrees a positions file holds on both axes for a stop with no known position.
pub const POSITION_UNKNOWN_MICRODEGREES: i32 = i32::MIN;

/// The kinds of a decoding result, by the names the JavaScript's `DecodeKind` gives them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecodeKind {
    Decoded,
    Refused,
}

impl DecodeKind {
    /// Every kind, in the JavaScript's order.
    pub const ALL: [Self; 2] = [Self::Decoded, Self::Refused];

    /// The kind's name, the `kind` a JavaScript result carries.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Decoded => "decoded",
            Self::Refused => "refused",
        }
    }
}

/// Why a file was refused, by the names the JavaScript's `RefusalReason` gives them.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum RefusalReason {
    InvalidHeader,
    UnsupportedVersion,
    InvalidLength,
    InvalidText,
    InvalidPosition,
}

impl RefusalReason {
    /// Every reason, in the JavaScript's order.
    pub const ALL: [Self; 5] = [
        Self::InvalidHeader,
        Self::UnsupportedVersion,
        Self::InvalidLength,
        Self::InvalidText,
        Self::InvalidPosition,
    ];

    /// The reason's name, the `reason` a JavaScript refusal carries.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::InvalidHeader => "invalidHeader",
            Self::UnsupportedVersion => "unsupportedVersion",
            Self::InvalidLength => "invalidLength",
            Self::InvalidText => "invalidText",
            Self::InvalidPosition => "invalidPosition",
        }
    }
}

// The kind numbers a header holds.
#[derive(Debug, Clone, Copy)]
enum FileKind {
    Stops,
    Trips,
    Transfers,
    Connections,
    Positions,
}

impl FileKind {
    const fn number(self) -> u16 {
        match self {
            Self::Stops => 1,
            Self::Trips => 2,
            Self::Transfers => 3,
            Self::Connections => 4,
            Self::Positions => 5,
        }
    }
}

/// A trip of a trips file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Trip {
    pub id: String,
    pub route_id: String,
    pub service_day_offset: u8,
}

/// The walking links of a transfers file, by column, one index a link.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Transfers {
    pub from_stop: Vec<u32>,
    pub to_stop: Vec<u32>,
    pub duration_s: Vec<u32>,
}

/// The connections of a connections file in departure order, by column, one
/// index a connection; `boarding` and `alighting` hold 1 where the flag is set
/// and 0 where it is not.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Connections {
    pub departure_s: Vec<i32>,
    pub arrival_s: Vec<i32>,
    pub departure_stop: Vec<u32>,
    pub arrival_stop: Vec<u32>,
    pub trip: Vec<u32>,
    pub sequence: Vec<u16>,
    pub boarding: Vec<u8>,
    pub alighting: Vec<u8>,
}

/// The stop positions of a positions file in the order of the stops file, in
/// microdegrees by axis; a stop with no known position holds
/// `POSITION_UNKNOWN_MICRODEGREES` on both.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Positions {
    pub lat_microdegrees: Vec<i32>,
    pub lon_microdegrees: Vec<i32>,
}

// The header's record count, or the reason the header is refused.
fn read_header(bytes: &[u8], kind: FileKind) -> Result<usize, RefusalReason> {
    if bytes.len() < HEADER_BYTES {
        return Err(RefusalReason::InvalidHeader);
    }

    if !bytes.starts_with(FORMAT_MAGIC) {
        return Err(RefusalReason::InvalidHeader);
    }

    let version = checked(u16_at(bytes, VERSION_OFFSET), VERSION_OFFSET);

    if version != FORMAT_VERSION {
        return Err(RefusalReason::UnsupportedVersion);
    }

    let file_kind = checked(u16_at(bytes, KIND_OFFSET), KIND_OFFSET);

    if file_kind != kind.number() {
        return Err(RefusalReason::InvalidHeader);
    }

    let count = checked(u32_at(bytes, COUNT_OFFSET), COUNT_OFFSET);
    Ok(index_of(count))
}

// The string at `offset` and the offset after it, or the reason it is refused.
fn read_string(bytes: &[u8], offset: usize) -> Result<(String, usize), RefusalReason> {
    let Some(length) = u16_at(bytes, offset) else {
        return Err(RefusalReason::InvalidLength);
    };
    let text_start = sum(offset, STRING_LENGTH_BYTES);
    let text_end = sum(text_start, usize::from(length));
    let Some(text_bytes) = bytes.get(text_start..text_end) else {
        return Err(RefusalReason::InvalidLength);
    };
    let Ok(text) = std::str::from_utf8(text_bytes) else {
        return Err(RefusalReason::InvalidText);
    };
    let without_mark = text.strip_prefix(BYTE_ORDER_MARK).unwrap_or(text);
    Ok((without_mark.to_owned(), text_end))
}

// The most records a file of `bytes` can hold at `record_bytes_min` each, the
// bound a count read from the file is held to before anything is allocated.
fn capacity_bound(bytes: &[u8], count: usize, record_bytes_min: usize) -> usize {
    let body_bytes = bytes.len().saturating_sub(HEADER_BYTES);
    let records_max = body_bytes.checked_div(record_bytes_min).unwrap_or(0);
    count.min(records_max)
}

// The records of a file of fixed-size records after the header, each
// `record_bytes` long, or a refusal when the file is not `count` of them.
fn fixed_records(
    bytes: &[u8],
    count: usize,
    record_bytes: usize,
) -> Result<std::slice::ChunksExact<'_, u8>, RefusalReason> {
    let expected_length = count
        .checked_mul(record_bytes)
        .and_then(|records_length| records_length.checked_add(HEADER_BYTES));

    if expected_length != Some(bytes.len()) {
        return Err(RefusalReason::InvalidLength);
    }

    let body = checked(bytes.get(HEADER_BYTES..), HEADER_BYTES);
    Ok(body.chunks_exact(record_bytes))
}

/// The stop identifiers of a stops file, a stop's index being its position.
///
/// # Errors
///
/// The reason the file is refused: its header, its length, or a string that
/// is no UTF-8.
pub fn decode_stops(bytes: &[u8]) -> Result<Vec<String>, RefusalReason> {
    let count = read_header(bytes, FileKind::Stops)?;
    let mut stop_ids = Vec::with_capacity(capacity_bound(bytes, count, STRING_LENGTH_BYTES));
    let mut offset = HEADER_BYTES;

    // Each string takes at least its length's bytes, so the loop ends within
    // the file's bytes whatever the count claims.
    for _ in 0..count {
        let (text, next) = read_string(bytes, offset)?;
        stop_ids.push(text);
        offset = next;
    }

    if offset != bytes.len() {
        return Err(RefusalReason::InvalidLength);
    }

    Ok(stop_ids)
}

/// The trips of a trips file: identifier, route, and service day offset.
///
/// # Errors
///
/// The reason the file is refused: its header, its length, or a string that
/// is no UTF-8.
pub fn decode_trips(bytes: &[u8]) -> Result<Vec<Trip>, RefusalReason> {
    let count = read_header(bytes, FileKind::Trips)?;
    let trip_bytes_min = sum(
        sum(STRING_LENGTH_BYTES, STRING_LENGTH_BYTES),
        SERVICE_DAY_OFFSET_BYTES,
    );
    let mut trips = Vec::with_capacity(capacity_bound(bytes, count, trip_bytes_min));
    let mut offset = HEADER_BYTES;

    for _ in 0..count {
        let (id, route_offset) = read_string(bytes, offset)?;
        let (route_id, day_offset) = read_string(bytes, route_offset)?;
        let Some(service_day_offset) = u8_at(bytes, day_offset) else {
            return Err(RefusalReason::InvalidLength);
        };
        trips.push(Trip {
            id,
            route_id,
            service_day_offset,
        });
        offset = sum(day_offset, SERVICE_DAY_OFFSET_BYTES);
    }

    if offset != bytes.len() {
        return Err(RefusalReason::InvalidLength);
    }

    Ok(trips)
}

/// The walking links of a transfers file, by column.
///
/// # Errors
///
/// The reason the file is refused: its header, or a length that is not its
/// count of links.
pub fn decode_transfers(bytes: &[u8]) -> Result<Transfers, RefusalReason> {
    let count = read_header(bytes, FileKind::Transfers)?;
    let records = fixed_records(bytes, count, TRANSFER_BYTES)?;
    let mut transfers = Transfers {
        from_stop: Vec::with_capacity(count),
        to_stop: Vec::with_capacity(count),
        duration_s: Vec::with_capacity(count),
    };

    for record in records {
        transfers.from_stop.push(checked(u32_at(record, 0), 0));
        transfers.to_stop.push(checked(
            u32_at(record, TRANSFER_TO_STOP_OFFSET),
            TRANSFER_TO_STOP_OFFSET,
        ));
        transfers.duration_s.push(checked(
            u32_at(record, TRANSFER_DURATION_OFFSET),
            TRANSFER_DURATION_OFFSET,
        ));
    }

    Ok(transfers)
}

// Whether a position read from a file is one the format admits: known on both
// axes inside their ranges, or unknown on both.
const fn is_admitted_position(lat_microdegrees: i32, lon_microdegrees: i32) -> bool {
    let is_lat_unknown = lat_microdegrees == POSITION_UNKNOWN_MICRODEGREES;
    let is_lon_unknown = lon_microdegrees == POSITION_UNKNOWN_MICRODEGREES;
    let is_unknown = is_lat_unknown && is_lon_unknown;

    if is_unknown {
        return true;
    }

    let is_lat_in_range = lat_microdegrees.unsigned_abs() <= LAT_MICRODEGREES_MAX;
    let is_lon_in_range = lon_microdegrees.unsigned_abs() <= LON_MICRODEGREES_MAX;
    is_lat_in_range && is_lon_in_range
}

/// The stop positions of a positions file, by axis.
///
/// # Errors
///
/// The reason the file is refused: its header, a length that is not its count
/// of positions, or a position out of range or unknown on one axis alone.
pub fn decode_positions(bytes: &[u8]) -> Result<Positions, RefusalReason> {
    let count = read_header(bytes, FileKind::Positions)?;
    let records = fixed_records(bytes, count, POSITION_BYTES)?;
    let mut positions = Positions {
        lat_microdegrees: Vec::with_capacity(count),
        lon_microdegrees: Vec::with_capacity(count),
    };

    for record in records {
        let lat_microdegrees = checked(i32_at(record, 0), 0);
        let lon_microdegrees = checked(i32_at(record, POSITION_LON_OFFSET), POSITION_LON_OFFSET);

        if !is_admitted_position(lat_microdegrees, lon_microdegrees) {
            return Err(RefusalReason::InvalidPosition);
        }

        positions.lat_microdegrees.push(lat_microdegrees);
        positions.lon_microdegrees.push(lon_microdegrees);
    }

    Ok(positions)
}

const fn flag_set(flags: u8, bit: u8) -> u8 {
    if flags & bit == 0 {
        return 0;
    }

    1
}

/// The connections of a connections file, in departure order, by column.
///
/// # Errors
///
/// The reason the file is refused: its header, or a length that is not its
/// count of connections.
pub fn decode_connections(bytes: &[u8]) -> Result<Connections, RefusalReason> {
    let count = read_header(bytes, FileKind::Connections)?;
    let records = fixed_records(bytes, count, CONNECTION_BYTES)?;
    let mut connections = Connections {
        departure_s: Vec::with_capacity(count),
        arrival_s: Vec::with_capacity(count),
        departure_stop: Vec::with_capacity(count),
        arrival_stop: Vec::with_capacity(count),
        trip: Vec::with_capacity(count),
        sequence: Vec::with_capacity(count),
        boarding: Vec::with_capacity(count),
        alighting: Vec::with_capacity(count),
    };

    for record in records {
        let flags = checked(
            u8_at(record, CONNECTION_FLAGS_OFFSET),
            CONNECTION_FLAGS_OFFSET,
        );
        connections.departure_s.push(checked(i32_at(record, 0), 0));
        connections.arrival_s.push(checked(
            i32_at(record, CONNECTION_ARRIVAL_OFFSET),
            CONNECTION_ARRIVAL_OFFSET,
        ));
        connections.departure_stop.push(checked(
            u32_at(record, CONNECTION_DEPARTURE_STOP_OFFSET),
            CONNECTION_DEPARTURE_STOP_OFFSET,
        ));
        connections.arrival_stop.push(checked(
            u32_at(record, CONNECTION_ARRIVAL_STOP_OFFSET),
            CONNECTION_ARRIVAL_STOP_OFFSET,
        ));
        connections.trip.push(checked(
            u32_at(record, CONNECTION_TRIP_OFFSET),
            CONNECTION_TRIP_OFFSET,
        ));
        connections.sequence.push(checked(
            u16_at(record, CONNECTION_SEQUENCE_OFFSET),
            CONNECTION_SEQUENCE_OFFSET,
        ));
        connections.boarding.push(flag_set(flags, BOARDING_BIT));
        connections.alighting.push(flag_set(flags, ALIGHTING_BIT));
    }

    Ok(connections)
}
