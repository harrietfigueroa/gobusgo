//! The stops a rider at a position can walk to before a first ride.
//!
//! A port of `assets/js/core/routing_walk.js`, by the rules of a snapshot's
//! walking links, so a journey can start from the rider's position with no
//! request: the position stays on the device. Everything here is pure.
//!
//! A stop is a start when it lies within the snapshot's walking radius in a
//! straight line, and its walk takes that distance at the snapshot's walking
//! speed, rounded up to the second. The nearest are kept, at most as many as
//! the walking links a stop keeps.
//!
//! Where the snapshot's links are measured along the streets, a walk from a
//! position is too: the stops within the straight-line radius are the
//! candidates, and the street meters the walk graph gives them decide which
//! are starts and how long each walk takes.
//!
//! A rule, a stop, and a walk's seconds are doubles, as the JavaScript compares
//! and writes them, so a refusal's message reads the same from both cores.

use std::cmp::Ordering;

use crate::assert::{self, number_text};
use crate::bytes::number_of;
use crate::math::geodesy::{Between, Position, distance_meters};
use crate::routing_snapshot::{POSITION_UNKNOWN_MICRODEGREES, Positions};

/// The most candidates a walk from a position over the streets searches for,
/// the nearest in a straight line.
pub const WALK_CANDIDATE_COUNT_MAX: usize = 256;

const MICRODEGREES_PER_DEGREE: f64 = 1_000_000.0;
const LAT_DEGREES_MAX: f64 = 90.0;
const LON_DEGREES_MAX: f64 = 180.0;

const BOUND_NOT_A_NUMBER_MESSAGE: &str = "routing walk: the street length bound is not a number";

// JavaScript writes a property an object does not hold as `undefined`.
const ABSENT_TEXT: &str = "undefined";

/// How a snapshot's walking links are measured, by the JavaScript's names.
///
/// Along a straight line, along the streets of the walk graph, or a mix of the
/// two, a table that stands in for one not current, whose links to a stop new
/// or moved since are straight.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WalkBasis {
    Straight,
    Streets,
    Mixed,
}

impl WalkBasis {
    /// Every basis, in the JavaScript's order.
    pub const ALL: [Self; 3] = [Self::Straight, Self::Streets, Self::Mixed];

    /// The basis's name, the value a manifest's `walkBasis` holds.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Straight => "straight",
            Self::Streets => "streets",
            Self::Mixed => "mixed",
        }
    }

    /// The basis `name` names, which must be one.
    #[must_use]
    #[track_caller]
    pub fn named(name: &str) -> Self {
        let Some(basis) = Self::known(name) else {
            assert::unreachable(&name, "routing walk: a walking basis of unknown kind");
        };
        basis
    }

    fn known(name: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|basis| basis.name() == name)
    }
}

/// The rules of a manifest entry's `transferRules` a walk from a position follows.
///
/// The walking radius in meters, the walking speed in meters a second, and the
/// walking links a stop keeps, which must be whole.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct WalkRules {
    pub walk_radius_m: f64,
    pub walk_speed_m_per_s: f64,
    pub walk_link_count_per_stop_max: f64,
}

/// A rider's position in degrees, the stop positions of a decoded positions
/// file, and the walking rules a walk from the position follows.
#[derive(Debug, Clone, Copy)]
pub struct Near<'positions> {
    pub position: Position,
    pub positions: &'positions Positions,
    pub rules: WalkRules,
}

/// A start stop, by its index, and the whole seconds of the walk to it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Start {
    pub stop: f64,
    pub walk_s: f64,
}

/// A stop a walk over the streets searches for, by its index, and its position
/// in degrees.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Candidate {
    pub stop: f64,
    pub lat: f64,
    pub lon: f64,
}

/// A stop a walk over the streets reached, by its index, and the meters of
/// street to it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct ReachedStop {
    pub stop: f64,
    pub street_m: f64,
}

// A stop with a known position within the walking radius, with its distance
// in a straight line.
struct NearStop {
    stop: f64,
    distance_m: f64,
    lat: f64,
    lon: f64,
}

// The order of two numbers a JavaScript comparator that subtracts them gives,
// the two zeros equal; NaN, which no caller hands, takes `total_cmp`'s place,
// so the order stays total.
fn number_order(left: f64, right: f64) -> Ordering {
    match left.partial_cmp(&right) {
        Some(order) => order,
        None => left.total_cmp(&right),
    }
}

fn by_distance(left: &NearStop, right: &NearStop) -> Ordering {
    let by_meters = number_order(left.distance_m, right.distance_m);
    by_meters.then_with(|| number_order(left.stop, right.stop))
}

fn by_street_meters(left: &ReachedStop, right: &ReachedStop) -> Ordering {
    let by_meters = number_order(left.street_m, right.street_m);
    by_meters.then_with(|| number_order(left.stop, right.stop))
}

#[track_caller]
fn assert_position(position: Position) {
    assert::condition(position.lat.is_finite(), || {
        format!(
            "routing walk: the position's latitude is not a number: {}",
            number_text(position.lat)
        )
    });
    assert::condition(position.lon.is_finite(), || {
        format!(
            "routing walk: the position's longitude is not a number: {}",
            number_text(position.lon)
        )
    });
    assert::condition(position.lat.abs() <= LAT_DEGREES_MAX, || {
        format!(
            "routing walk: the position's latitude is out of range: {}",
            number_text(position.lat)
        )
    });
    assert::condition(position.lon.abs() <= LON_DEGREES_MAX, || {
        format!(
            "routing walk: the position's longitude is out of range: {}",
            number_text(position.lon)
        )
    });
}

#[track_caller]
fn assert_rules(rules: WalkRules) {
    assert::condition(rules.walk_radius_m > 0.0, || {
        format!(
            "routing walk: the walking radius is not positive: {}",
            number_text(rules.walk_radius_m)
        )
    });
    assert::condition(rules.walk_speed_m_per_s > 0.0, || {
        format!(
            "routing walk: the walking speed is not positive: {}",
            number_text(rules.walk_speed_m_per_s)
        )
    });
    assert::condition(is_whole(rules.walk_link_count_per_stop_max), || {
        format!(
            "routing walk: the link count is not whole: {}",
            number_text(rules.walk_link_count_per_stop_max)
        )
    });
}

// JavaScript's `Number.isInteger`.
fn is_whole(value: f64) -> bool {
    let is_finite = value.is_finite();
    let is_unchanged = value.trunc().total_cmp(&value).is_eq();
    is_finite && is_unchanged
}

// The first items of `items` that JavaScript's `slice(0, end)` keeps, for a
// whole `end`, which counts back from the last item where it is negative.
fn kept_first<Item>(items: Vec<Item>, end: f64) -> Vec<Item> {
    let length = number_of(items.len());
    let count = if end < 0.0 {
        (length + end).max(0.0)
    } else {
        end.min(length)
    };
    let mut kept = Vec::new();

    for item in items {
        let kept_count = number_of(kept.len());

        if kept_count >= count {
            break;
        }

        kept.push(item);
    }

    kept
}

// The stops with a known position within the walking radius of the position
// in a straight line, nearest first, equal distances going to the lower stop.
#[track_caller]
fn stops_within(near: &Near<'_>) -> Vec<NearStop> {
    assert_position(near.position);
    assert_rules(near.rules);
    let Positions {
        lat_microdegrees,
        lon_microdegrees,
    } = near.positions;
    assert::condition(lat_microdegrees.len() == lon_microdegrees.len(), || {
        "routing walk: the position columns differ in length".to_owned()
    });
    let mut within = Vec::new();

    for (index, (&lat_value, &lon_value)) in
        lat_microdegrees.iter().zip(lon_microdegrees).enumerate()
    {
        if lat_value == POSITION_UNKNOWN_MICRODEGREES {
            continue;
        }

        let lat = f64::from(lat_value) / MICRODEGREES_PER_DEGREE;
        let lon = f64::from(lon_value) / MICRODEGREES_PER_DEGREE;
        let distance_m = distance_meters(Between {
            source: near.position,
            target: Position { lon, lat },
        });

        if distance_m <= near.rules.walk_radius_m {
            within.push(NearStop {
                stop: number_of(index),
                distance_m,
                lat,
                lon,
            });
        }
    }

    within.sort_by(by_distance);
    within
}

/// The basis of a manifest entry's `transferRules`.
///
/// It is read from the entry's `walkBasis`, where that is text, and its
/// `walkStreetMetersMax`, where it holds one. A manifest that names none, one
/// this reader does not know, or a streets or mixed basis whose bound is not a
/// positive finite number, is a straight-line table.
#[must_use]
pub fn walk_basis_of(walk_basis: Option<&str>, walk_street_meters_max: Option<f64>) -> WalkBasis {
    let known = match walk_basis {
        Some(name) => WalkBasis::known(name),
        None => None,
    };
    let Some(basis) = known else {
        return WalkBasis::Straight;
    };

    let is_straight = basis == WalkBasis::Straight;
    let is_bounded = match walk_street_meters_max {
        Some(meters) => is_positive_finite(meters),
        None => false,
    };

    let is_usable = is_straight || is_bounded;

    if is_usable {
        return basis;
    }

    WalkBasis::Straight
}

fn is_positive_finite(value: f64) -> bool {
    let is_finite = value.is_finite();
    let is_positive = value > 0.0;
    is_finite && is_positive
}

/// Whether a walk from a position or to a point is planned along the streets.
///
/// A mixed table is planned on the streets too: the walk graph a walk is drawn
/// along is the one a page reads, and the stops a mixed table has no measure of
/// are the table's own limit, which a rider's own walk does not inherit.
#[must_use]
pub const fn is_street_walk(basis: WalkBasis) -> bool {
    match basis {
        WalkBasis::Straight => false,
        WalkBasis::Streets | WalkBasis::Mixed => true,
    }
}

/// The street length, in meters, that a walk over the streets may have: a
/// manifest entry's `walkStreetMetersMax`, which it must hold as a positive
/// finite number for the streets and for a mix.
#[must_use]
#[track_caller]
pub fn street_meters_max_of(walk_street_meters_max: Option<f64>) -> f64 {
    assert::condition(walk_street_meters_max.is_some(), || {
        format!("{BOUND_NOT_A_NUMBER_MESSAGE}: {ABSENT_TEXT}")
    });
    let Some(meters) = walk_street_meters_max else {
        assert::unreachable(
            &ABSENT_TEXT,
            "routing walk: a street length bound checked to be held is held",
        );
    };
    assert::condition(meters.is_finite(), || {
        format!("{BOUND_NOT_A_NUMBER_MESSAGE}: {}", number_text(meters))
    });
    assert::condition(meters > 0.0, || {
        format!(
            "routing walk: the street length bound is not positive: {}",
            number_text(meters)
        )
    });
    meters
}

/// The start stops within walking distance of the position.
///
/// Each stop comes with the whole seconds of its walk, nearest first, at most
/// the walking links a stop keeps. Stops with no known position are never
/// starts.
#[must_use]
#[track_caller]
pub fn starts_near(near: &Near<'_>) -> Vec<Start> {
    let within = stops_within(near);
    let kept = kept_first(within, near.rules.walk_link_count_per_stop_max);
    let mut starts = Vec::with_capacity(kept.len());

    for candidate in kept {
        let walk_s = (candidate.distance_m / near.rules.walk_speed_m_per_s).ceil();
        starts.push(Start {
            stop: candidate.stop,
            walk_s,
        });
    }

    starts
}

/// The stops a walk from the position over the streets searches among: those
/// within the walking radius in a straight line, nearest first, at most
/// `WALK_CANDIDATE_COUNT_MAX`.
#[must_use]
#[track_caller]
pub fn walk_candidates_near(near: &Near<'_>) -> Vec<Candidate> {
    let mut within = stops_within(near);
    within.truncate(WALK_CANDIDATE_COUNT_MAX);
    let mut candidates = Vec::with_capacity(within.len());

    for near_stop in within {
        candidates.push(Candidate {
            stop: near_stop.stop,
            lat: near_stop.lat,
            lon: near_stop.lon,
        });
    }

    candidates
}

/// The start stops of a walk over the streets.
///
/// `stops` are the stops a reach found and their street meters, each given the
/// whole seconds of its walk at the snapshot's walking speed, nearest by street
/// first, equal lengths going to the lower stop, at most the walking links a
/// stop keeps, as `starts_near`
/// answers them.
#[must_use]
#[track_caller]
pub fn starts_from_streets(stops: &[ReachedStop], rules: WalkRules) -> Vec<Start> {
    assert_rules(rules);
    let mut ordered = stops.to_vec();
    ordered.sort_by(by_street_meters);
    let kept = kept_first(ordered, rules.walk_link_count_per_stop_max);
    let mut starts = Vec::with_capacity(kept.len());

    for reached in kept {
        let walk_s = (reached.street_m / rules.walk_speed_m_per_s).ceil();
        starts.push(Start {
            stop: reached.stop,
            walk_s,
        });
    }

    starts
}
