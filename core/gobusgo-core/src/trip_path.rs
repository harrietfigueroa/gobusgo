//! A running trip's path as the vehicle page receives it, decoded, and the
//! page's bounded cache of the paths it holds.
//!
//! A port of `assets/js/core/trip_path.js`. Everything here is pure: a decoder
//! takes the event's values, and the cache's function takes a cache and
//! returns another.
//!
//! A path arrives with `points` in the encoded polyline format and `stops` as
//! three numbers per stop in the same format's number encoding: the distance
//! since the stop before in meters, the arrival since the stop before's arrival
//! in seconds, and the departure after the arrival, the first stop's taken from
//! zero.
//! <https://developers.google.com/maps/documentation/utilities/polylinealgorithm> — checked 2026-11-09

use crate::assert::{self, number_text};

/// The most paths the page holds.
pub const TRIP_PATH_COUNT_MAX: usize = 300;

/// The message of the failure for encoded numbers that are no text, for a
/// binding whose platform passes a value of another type.
pub const ENCODED_NOT_TEXT_MESSAGE: &str = "encoded numbers must be a string";

/// The message of the failure for a trip identifier that is no text, for a
/// binding whose platform passes a value of another type.
pub const TRIP_ID_NOT_TEXT_MESSAGE: &str = "a trip identifier must be text";

const CHARACTER_OFFSET: u16 = 63;
const CHARACTER_MAX: u16 = 126;
const CHUNK_BITS: u32 = 5;
const CHUNK_MASK: u16 = 0x1F;
const CHUNK_CONTINUES: u16 = 0x20;
// Seven chunks hold 35 bits, of which 32 are kept, enough for every number a
// path holds: a coordinate times 100,000 and doubled for its sign, a distance,
// or a time.
const NUMBER_CHUNK_COUNT_MAX: u32 = 7;
const COORDINATE_PRECISION: f64 = 100_000.0;
// A point is two numbers, latitude then longitude; a stop is three, its
// distance step, its arrival step, and its dwell.
const NUMBERS_PER_POINT: usize = 2;
const NUMBERS_PER_STOP: usize = 3;
// Each stop is checked against the one before it.
const STOPS_PER_COMPARISON: usize = 2;

/// A stop of a path: its distance along the points in meters, and its
/// scheduled arrival and departure in seconds from the start of the service day.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Stop {
    pub distance_meters: f64,
    pub arrival_seconds: f64,
    pub departure_seconds: f64,
}

/// A point of a path in degrees, longitude first.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Point {
    pub longitude: f64,
    pub latitude: f64,
}

/// What a path is held under: its trip and the start of its service day, in
/// milliseconds since the Unix epoch.
#[derive(Debug, Clone, Copy)]
pub struct KeyOf<'trip> {
    pub trip_id: &'trip str,
    pub service_date_ms: f64,
}

/// One path as the event carries it.
#[derive(Debug, Clone, Copy)]
pub struct EncodedPath<'path> {
    pub trip_id: &'path str,
    pub service_date_ms: f64,
    pub points: &'path str,
    pub stops: &'path str,
}

/// A decoded path's points, its stops, and the key it is held under.
#[derive(Debug, Clone, PartialEq)]
pub struct DecodedPath {
    pub key: String,
    pub points: Vec<Point>,
    pub stops: Vec<Stop>,
}

/// What `trip_path_of` checks of a path its caller decoded: its key's parts,
/// how many points it has, and its stops' distances, in the order the trip
/// serves them.
#[derive(Debug, Clone, Copy)]
pub struct TripPathParts<'path> {
    pub trip_id: &'path str,
    pub service_date_ms: f64,
    pub point_count: usize,
    pub stop_distances_meters: &'path [f64],
}

// The numbers `encoded` holds, each written lowest chunk first with its sign
// in the lowest bit. A number of more chunks than the bound is refused rather
// than read wrong. A character's index is its UTF-16 index, as the JavaScript
// counts it.
fn decode_numbers(encoded: &str) -> Vec<i32> {
    let mut numbers = Vec::with_capacity(encoded.len());
    let mut value: u32 = 0;
    let mut chunk_count: u32 = 0;

    for (index, code) in encoded.encode_utf16().enumerate() {
        assert::condition(code >= CHARACTER_OFFSET, || {
            format!("character {index} lies below the encoded format")
        });
        assert::condition(code <= CHARACTER_MAX, || {
            format!("character {index} lies above the encoded format")
        });
        assert::condition(chunk_count < NUMBER_CHUNK_COUNT_MAX, || {
            format!("a number holds at most {NUMBER_CHUNK_COUNT_MAX} chunks")
        });
        let chunk = code.saturating_sub(CHARACTER_OFFSET);
        value |= chunk_bits(chunk & CHUNK_MASK, chunk_count);
        chunk_count = chunk_count.saturating_add(1);

        if chunk < CHUNK_CONTINUES {
            numbers.push(signed_number(value));
            value = 0;
            chunk_count = 0;
        }
    }

    assert::condition(chunk_count == 0, || {
        "the encoded text ends inside a number".to_owned()
    });
    numbers
}

// A chunk's bits at its place in a number, the bits past 32 dropped as the
// JavaScript's bit operators drop them.
fn chunk_bits(chunk: u16, chunk_count: u32) -> u32 {
    let shift = chunk_count.saturating_mul(CHUNK_BITS);
    let Some(bits) = u32::from(chunk).checked_shl(shift) else {
        assert::unreachable(&shift, "trip path: a chunk's shift is under 32");
    };
    bits
}

// The lowest bit carries the sign.
fn signed_number(value: u32) -> i32 {
    let Ok(half) = i32::try_from(value >> 1) else {
        assert::unreachable(&value, "trip path: half a u32 fits an i32");
    };

    if value & 1 == 1 {
        return !half;
    }

    half
}

fn decode_points(encoded: &str) -> Vec<Point> {
    let numbers = decode_numbers(encoded);
    assert::condition(numbers.len().is_multiple_of(NUMBERS_PER_POINT), || {
        "a point holds a latitude and a longitude".to_owned()
    });
    let (pairs, _) = numbers.as_chunks::<NUMBERS_PER_POINT>();
    let mut points = Vec::with_capacity(pairs.len());
    let mut latitude = 0.0;
    let mut longitude = 0.0;

    for &[latitude_step, longitude_step] in pairs {
        latitude += f64::from(latitude_step);
        longitude += f64::from(longitude_step);
        points.push(Point {
            longitude: longitude / COORDINATE_PRECISION,
            latitude: latitude / COORDINATE_PRECISION,
        });
    }

    points
}

fn decode_stops(encoded: &str) -> Vec<Stop> {
    let numbers = decode_numbers(encoded);
    assert::condition(numbers.len().is_multiple_of(NUMBERS_PER_STOP), || {
        "a stop holds three numbers".to_owned()
    });
    let (triples, _) = numbers.as_chunks::<NUMBERS_PER_STOP>();
    let mut stops = Vec::with_capacity(triples.len());
    let mut distance_meters = 0.0;
    let mut arrival_seconds = 0.0;

    for &[distance_step, arrival_step, dwell] in triples {
        distance_meters += f64::from(distance_step);
        arrival_seconds += f64::from(arrival_step);
        let departure_seconds = arrival_seconds + f64::from(dwell);
        stops.push(Stop {
            distance_meters,
            arrival_seconds,
            departure_seconds,
        });
    }

    stops
}

/// The largest integer a double holds exactly, with every integer below it.
const SAFE_INTEGER_MAX: f64 = 9_007_199_254_740_991.0;

fn is_safe_integer(value: f64) -> bool {
    let is_integer = value.fract() == 0.0;
    let is_in_range = value.abs() <= SAFE_INTEGER_MAX;
    is_integer && is_in_range
}

/// The key a path is held under: the start of its service day, a slash, and
/// its trip. The trip must not be empty and the service date must be an integer.
#[must_use]
pub fn trip_path_key(key: KeyOf<'_>) -> String {
    let KeyOf {
        trip_id,
        service_date_ms,
    } = key;
    assert::condition(!trip_id.is_empty(), || {
        "a trip identifier must not be empty".to_owned()
    });
    assert::condition(is_safe_integer(service_date_ms), || {
        "a service date must be an integer".to_owned()
    });
    format!("{}/{trip_id}", number_text(service_date_ms))
}

/// The key of a path its caller decoded.
///
/// The path must hold at least one point and one stop and no stop before the
/// stop before it. Every decoder of a path checks it here, so a path has one
/// shape wherever it was read from.
#[must_use]
pub fn trip_path_of(parts: TripPathParts<'_>) -> String {
    let TripPathParts {
        trip_id,
        service_date_ms,
        point_count,
        stop_distances_meters,
    } = parts;
    assert::condition(point_count > 0, || {
        "a path holds at least one point".to_owned()
    });
    assert::condition(!stop_distances_meters.is_empty(), || {
        "a path holds at least one stop".to_owned()
    });

    for (index, pair) in stop_distances_meters
        .windows(STOPS_PER_COMPARISON)
        .enumerate()
    {
        let &[before, distance] = pair else {
            assert::unreachable(&pair.len(), "trip path: a window holds two stops");
        };
        assert::condition(distance >= before, || {
            format!(
                "stop {} lies before the stop before it",
                index.saturating_add(1)
            )
        });
    }

    trip_path_key(KeyOf {
        trip_id,
        service_date_ms,
    })
}

/// One encoded path, decoded.
///
/// Its points, and each stop's distance along them in meters and its
/// scheduled times in seconds from `service_date_ms`, in the order the trip
/// serves them. A stop's distance is the sum of haversine
/// distances between the points on a sphere of radius 6,371,008.8 m.
#[must_use]
pub fn decode_trip_path(path: EncodedPath<'_>) -> DecodedPath {
    let points = decode_points(path.points);
    let stops = decode_stops(path.stops);
    let stop_distances_meters: Vec<f64> = stops.iter().map(|stop| stop.distance_meters).collect();
    let key = trip_path_of(TripPathParts {
        trip_id: path.trip_id,
        service_date_ms: path.service_date_ms,
        point_count: points.len(),
        stop_distances_meters: &stop_distances_meters,
    });
    DecodedPath { key, points, stops }
}

/// A cache holding `cache`'s entries and `paths`, each under its key.
///
/// It holds at most `TRIP_PATH_COUNT_MAX` of them in the order they were put:
/// a path put again moves to the back, and the paths put earliest leave first.
#[must_use]
pub fn with_trip_paths<Path>(
    cache: Vec<(String, Path)>,
    paths: Vec<(String, Path)>,
) -> Vec<(String, Path)> {
    let mut next = cache;

    for (key, path) in paths {
        next.retain(|(held_key, _)| *held_key != key);
        next.push((key, path));
    }

    let excess = next.len().saturating_sub(TRIP_PATH_COUNT_MAX);
    next.drain(..excess);
    next
}
