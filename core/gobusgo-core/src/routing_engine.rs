//! The connection scan engine over the routing snapshots.
//!
//! A port of `route` and `routeArrivingBy` of
//! `assets/js/core/routing_engine.js`. Everything here is pure: an engine is
//! built from a snapshot's decoded columns and answers a query with its Pareto
//! frontier over arrival time and changes, or over departure time and changes
//! for a query that arrives by a time.
//!
//! The scan runs in rounds. Round k finds, at every stop, the earliest arrival
//! and the earliest time a rider can board with at most k rides. It boards a
//! trip only where the round before could board in time, so a round adds
//! exactly one ride, and a rider stays aboard a trip once boarded. A query
//! starts from one origin stop, or from a set of start stops each reached by a
//! walk of its own from the rider's position. A rider can board on arrival at
//! the origin or a start stop or after a walk, and the snapshot's minimum
//! transfer after leaving a vehicle. One walking link may leave an origin stop,
//! none leaves a start stop, and one may follow each ride whenever the ride
//! reaches its stop earlier than any ride before it, whatever reached the stop
//! on foot. Each label keeps the leg that set it, and a walk keeps the ride it
//! follows, so the legs read back are the ones the scan used. A round's journey
//! joins the frontier only when it arrives strictly earlier than the round
//! before, so no journey kept has another that arrives at least as early with
//! at most as many changes.
//!
//! The scan reads the connections from the first one departing at or after the
//! query and stops at the first one departing at or after the best arrival, so
//! a set of connections cut off at a later departure gives every journey that
//! arrives by that departure exactly as the whole set does.
//!
//! A query that arrives by a time runs the same rules backward: round k finds,
//! at every stop, the latest time a rider can leave it and the latest time a
//! vehicle can arrive at it, with at most k rides still to take. It reads the
//! connections from the last one departing at or before the time down to the
//! first, so a trip's later hops come before its earlier ones, and it alights a
//! trip at the latest of its stops it can leave by then. A walk may reach the
//! target and one may come before each ride, mirroring the walks of a forward
//! query, and a start stop is left only by boarding. Its journey joins the
//! frontier only when it leaves strictly later than the round before, and of
//! start stops left at one time the first in the query's order is kept. It
//! stops at the first connection departing no later than the best departure
//! plus the shortest walk to a start stop, so a set of connections cut off at
//! an earlier departure gives every journey that leaves at or after it exactly
//! as the whole set does.
//!
//! An `Engine` owns the columns it is built from and what it builds once: each
//! stop's walking links out and in as offsets into link columns, and each
//! connection's trip numbered densely, so a query's state per trip is bounded
//! by the connection count. A query runs over an `EngineView`, the same columns
//! borrowed, which a binding can also make from arrays it holds.
//!
//! A query's stops, times, and walks are doubles, as the JavaScript compares
//! and writes them, so a refusal's message reads the same from both cores. A
//! label stores each time as the JavaScript's `Int32Array` stores it, its
//! `ToInt32`, and compares a new time with the stored one as a double, and a
//! leg reads its duration back through the same `ToInt32`, so a fractional
//! minimum transfer, a time past `i32::MAX`, or a walk longer than that is
//! answered as the JavaScript answers it. A query arriving by a time holds
//! each start stop's walk by stop through the same `ToInt32`.

use std::collections::BTreeMap;

use crate::assert::{self, number_text};
use crate::bytes::{index_of, number_of, sum};
use crate::routing_snapshot::{Connections, Transfers};
use crate::routing_walk::{Start, is_whole};

/// The most rides a journey takes, one a round.
pub const ROUNDS_MAX: usize = 6;

// The most legs a journey has: a ride a round, a walk after each, and one
// walk from the origin.
const LEG_COUNT_MAX: usize = ROUNDS_MAX + ROUNDS_MAX + 1;

// The time of a stop a query has not reached, the largest a label holds.
const UNREACHED_S: i32 = i32::MAX;

// The time of a stop a query arriving by a time cannot leave in time.
const UNLEFT_S: i32 = -0x7fff_ffff;

// The walk a query arriving by a time holds at a stop that is no start stop.
const NOT_A_START_S: i32 = -1;

// The count of values a 32-bit integer takes, and half of it, the first value
// ToInt32 wraps below zero.
const INT32_VALUE_COUNT: f64 = 4_294_967_296.0;
const INT32_VALUE_COUNT_HALF: f64 = 2_147_483_648.0;

const FLAG_SET: u8 = 1;

/// The kinds of a journey's legs, by the JavaScript's names.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LegKind {
    Ride,
    Walk,
    WalkFromPosition,
}

impl LegKind {
    /// Every kind, in the JavaScript's order.
    pub const ALL: [Self; 3] = [Self::Ride, Self::Walk, Self::WalkFromPosition];

    /// The kind's name, the `kind` of a JavaScript leg.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Ride => "ride",
            Self::Walk => "walk",
            Self::WalkFromPosition => "walkFromPosition",
        }
    }
}

/// The kinds of a query's origin, by the JavaScript's names: one stop, or
/// start stops with their walking times.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum OriginKind {
    Stop,
    Starts,
}

impl OriginKind {
    /// Every kind, in the JavaScript's order.
    pub const ALL: [Self; 2] = [Self::Stop, Self::Starts];

    /// The kind's name, the `kind` of a JavaScript origin.
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Stop => "stop",
            Self::Starts => "starts",
        }
    }
}

/// A snapshot's stop count, connections, walking links ordered by the stop
/// they leave, and minimum transfer in seconds, which an engine is built from.
#[derive(Debug, Clone, PartialEq)]
pub struct EngineInput {
    pub stop_count: usize,
    pub connections: Connections,
    pub transfers: Transfers,
    pub minimum_transfer_s: f64,
}

/// An engine over a snapshot, owning its columns and the links built from them.
#[derive(Debug, Clone, PartialEq)]
pub struct Engine {
    connections: Connections,
    trip_slot: Vec<u32>,
    trip_count: usize,
    transfers: Transfers,
    link_offsets: Vec<u32>,
    incoming: IncomingLinks,
    minimum_transfer_s: f64,
}

// The walking links into each stop: `from_stop` and `duration_s` ordered by the
// stop each link reaches, and `offsets` into them by that stop.
#[derive(Debug, Clone, PartialEq, Eq)]
struct IncomingLinks {
    offsets: Vec<u32>,
    from_stop: Vec<u32>,
    duration_s: Vec<u32>,
}

/// The columns of the connections a query scans, one index a connection.
///
/// `trip_slot` numbers each connection's trip below the view's `trip_count`,
/// and `boarding` and `alighting` hold 1 where the flag is set.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ConnectionColumns<'columns> {
    pub departure_s: &'columns [i32],
    pub arrival_s: &'columns [i32],
    pub departure_stop: &'columns [u32],
    pub arrival_stop: &'columns [u32],
    pub trip_slot: &'columns [u32],
    pub boarding: &'columns [u8],
    pub alighting: &'columns [u8],
}

/// The walking links a query follows: stop `s` leaves by the links from
/// `offsets[s]` up to `offsets[s + 1]`, so `offsets` holds one more than the
/// stop count, never decreases, and ends at the link count.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct LinkColumns<'columns> {
    pub offsets: &'columns [u32],
    pub to_stop: &'columns [u32],
    pub duration_s: &'columns [u32],
}

/// The walking links into each stop that a query arriving by a time follows.
///
/// Stop `s` is reached by the links from `offsets[s]` up to `offsets[s + 1]`,
/// so `offsets` holds as many values as the view's outgoing offsets, never
/// decreases, and ends at the count of incoming links.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct IncomingLinkColumns<'columns> {
    pub offsets: &'columns [u32],
    pub from_stop: &'columns [u32],
    pub duration_s: &'columns [u32],
}

/// An engine's columns, borrowed, which a query runs over; its stop count is
/// one less than its link offsets.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct EngineView<'columns> {
    pub connections: ConnectionColumns<'columns>,
    pub links: LinkColumns<'columns>,
    pub incoming: IncomingLinkColumns<'columns>,
    pub trip_count: usize,
    pub minimum_transfer_s: f64,
}

/// A query's origin: one stop, start stops each with the whole seconds of its
/// walk from the rider's position, or an origin of another kind.
///
/// An origin of another kind is named as JavaScript's `String` writes it, and
/// `route` and `route_arriving_by` refuse it.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Origin<'query> {
    Stop { stop: f64 },
    Starts { starts: &'query [Start] },
    Unknown { kind: &'query str },
}

/// A query leaving `origin` for the stop `target` at or after `departure_s`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Query<'query> {
    pub origin: Origin<'query>,
    pub target: f64,
    pub departure_s: f64,
}

/// A query from `origin` to the stop `target` arriving at or before
/// `arrival_s`.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct QueryArrivingBy<'query> {
    pub origin: Origin<'query>,
    pub target: f64,
    pub arrival_s: f64,
}

/// A leg of a journey: a ride from one connection to another, a walking link
/// between two stops, or the walk from the rider's position to a start stop.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum Leg {
    Ride {
        board_connection: usize,
        alight_connection: usize,
    },
    Walk {
        from_stop: usize,
        to_stop: usize,
        duration_s: f64,
    },
    WalkFromPosition {
        to_stop: usize,
        duration_s: f64,
    },
}

impl Leg {
    /// The leg's kind.
    #[must_use]
    pub const fn kind(&self) -> LegKind {
        match self {
            Self::Ride { .. } => LegKind::Ride,
            Self::Walk { .. } => LegKind::Walk,
            Self::WalkFromPosition { .. } => LegKind::WalkFromPosition,
        }
    }
}

/// A journey of a frontier: its arrival, its changes, and its legs.
#[derive(Debug, Clone, PartialEq)]
pub struct Journey {
    pub arrival_s: f64,
    pub changes: usize,
    pub legs: Vec<Leg>,
}

/// A journey of a frontier arriving by a time: the latest time it leaves the
/// origin, its arrival, its changes, and its legs.
#[derive(Debug, Clone, PartialEq)]
pub struct JourneyArrivingBy {
    pub departure_s: f64,
    pub arrival_s: f64,
    pub changes: usize,
    pub legs: Vec<Leg>,
}

// The leg that set a label at a stop. A ride and the walk after it hold the
// ride; a walk from a position holds the index of its start in the query.
#[derive(Debug, Clone, Copy, PartialEq)]
enum Parent {
    None,
    Ride { ride: RideBy },
    WalkAfterRide { ride: RideBy, duration_s: u32 },
    WalkFromOrigin { duration_s: u32 },
    WalkFromPosition { start: usize },
}

// The leg that set a label of a query arriving by a time at a stop. A ride and
// the walk before it hold the ride.
#[derive(Debug, Clone, Copy, PartialEq)]
enum ParentBack {
    None,
    Ride { ride: RideBy },
    WalkBeforeRide { ride: RideBy, duration_s: u32 },
    WalkToTarget { duration_s: u32 },
}

// The connections a ride boarded and left at, and the round that rode it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct RideBy {
    board: u32,
    alight: u32,
    round: u8,
}

// A stop, the time it is reached at, and the leg that reaches it.
#[derive(Debug, Clone, Copy)]
struct Step<SetBy> {
    stop: usize,
    time_s: f64,
    parent: SetBy,
}

// One label of a round: per stop, its time and the leg that set it. A label
// changes only through `improve`, `improve_later`, and `start_at`.
#[derive(Debug, Clone)]
struct Label<SetBy> {
    time_s: Vec<i32>,
    parent: Vec<SetBy>,
}

// The labels of one round, and the earliest a ride reached each stop.
#[derive(Debug, Clone)]
struct Round {
    arrival: Label<Parent>,
    ready: Label<Parent>,
    ride_arrival_s: Vec<i32>,
}

// The labels of one round of a query arriving by a time: per stop, the latest
// time a rider can leave it, the latest a vehicle can arrive at it, and the
// latest a ride boards there.
#[derive(Debug, Clone)]
struct RoundBack {
    depart: Label<ParentBack>,
    alight_by: Label<ParentBack>,
    boarded: Label<ParentBack>,
}

// A query's origin, its stops checked and read as indices.
#[derive(Debug, Clone, Copy)]
enum Checked<'query> {
    Stop(usize),
    Starts(&'query [Start]),
}

// A checked query.
#[derive(Debug, Clone, Copy)]
struct Search<'query> {
    origin: Checked<'query>,
    target: usize,
    departure_s: f64,
}

// A query arriving by a time, checked.
#[derive(Debug)]
struct SearchBack<'query> {
    origin: CheckedBack<'query>,
    target: usize,
    arrival_s: f64,
}

// The origin of a query arriving by a time, its stops checked and read as
// indices: one stop, or start stops with each one's walk held by stop as the
// JavaScript's `Int32Array` holds it, `NOT_A_START_S` at every other stop, and
// the shortest of their walks.
#[derive(Debug)]
enum CheckedBack<'query> {
    Stop(usize),
    Starts {
        starts: &'query [Start],
        walk_s_by_stop: Vec<i32>,
        walk_s_min: f64,
    },
}

// The walks from `stop`, reached at `arrival_s` after `ride`, or from the
// origin where there is none, into the labels of `state`.
#[derive(Debug)]
struct WalkFrom<'walk> {
    engine: &'walk EngineView<'walk>,
    state: &'walk mut Round,
    stop: usize,
    arrival_s: f64,
    ride: Option<RideBy>,
}

// The walks into `stop`, which `ride` leaves at `departure_s`, or into the
// target where there is no ride, into the labels of `state`.
#[derive(Debug)]
struct WalkInto<'walk> {
    engine: &'walk EngineView<'walk>,
    state: &'walk mut RoundBack,
    stop: usize,
    departure_s: f64,
    ride: Option<RideBy>,
}

// One round's scan: the round before, the round it fills, and the boarding
// connection of each trip, which it clears first.
#[derive(Debug)]
struct Scan<'scan> {
    engine: &'scan EngineView<'scan>,
    previous: &'scan Round,
    state: &'scan mut Round,
    boarded_at: &'scan mut [Option<usize>],
    search: Search<'scan>,
    round: u8,
}

// One round's scan of a query arriving by a time: the round before, the round
// it fills, and the alighting connection of each trip, which it clears first.
#[derive(Debug)]
struct ScanBack<'scan> {
    engine: &'scan EngineView<'scan>,
    previous: &'scan RoundBack,
    state: &'scan mut RoundBack,
    alighted_at: &'scan mut [Option<usize>],
    search: &'scan SearchBack<'scan>,
    round: u8,
}

// The rounds of a query, read back from round `round_index`.
#[derive(Debug, Clone, Copy)]
struct Reading<'reading> {
    engine: &'reading EngineView<'reading>,
    rounds: &'reading [Round],
    search: Search<'reading>,
    round_index: usize,
}

// The rounds of a query arriving by a time, read back from round
// `round_index`.
#[derive(Debug, Clone, Copy)]
struct ReadingBack<'reading> {
    engine: &'reading EngineView<'reading>,
    rounds: &'reading [RoundBack],
    search: &'reading SearchBack<'reading>,
    round_index: usize,
}

// A journey leaving the origin at `departure_s` along `legs`.
#[derive(Debug)]
struct Leaving {
    departure_s: f64,
    legs: Vec<Leg>,
}

// A round's origin of a query arriving by a time: left in time, or not.
#[derive(Debug)]
enum OriginJourney {
    Left(Leaving),
    Unleft,
}

// A column of stops and the name a refusal gives it.
#[derive(Debug, Clone, Copy)]
struct StopColumn<'column> {
    stops: &'column [u32],
    name: &'static str,
}

// A place and the time a rider leaves it at.
#[derive(Debug, Clone, Copy)]
struct Departure<Place> {
    from: Place,
    departure_s: f64,
}

// The value at `index` of `column`, which holds it.
#[track_caller]
fn at<Item: Copy>(column: &[Item], index: usize) -> Item {
    let Some(&value) = column.get(index) else {
        assert::unreachable(&index, "routing engine: an index of a column is inside it");
    };
    value
}

// `index` as a `u32`, which every index of a view's connections fits.
#[track_caller]
fn connection_number(index: usize) -> u32 {
    let Ok(number) = u32::try_from(index) else {
        assert::unreachable(&index, "routing engine: a connection's index fits a u32");
    };
    number
}

#[track_caller]
fn round_number(index: usize) -> u8 {
    let Ok(number) = u8::try_from(index) else {
        assert::unreachable(&index, "routing engine: a round's index fits a u8");
    };
    number
}

// JavaScript's `ToInt32`, which an `Int32Array` applies to each time it stores:
// the time truncated toward zero and wrapped modulo 2^32 into the signed range,
// and 0 for NaN and the infinities.
// https://tc39.es/ecma262/#sec-toint32 — checked 2026-11-24
fn int32_of(value: f64) -> i32 {
    let truncated = value.trunc();
    let is_in_range = (f64::from(i32::MIN)..=f64::from(i32::MAX)).contains(&truncated);
    let signed = if is_in_range {
        truncated
    } else {
        wrapped_int32(truncated)
    };
    // `signed` is a whole number within the range of an `i32`, so the cast is
    // exact, and the standard library converts a double to an integer by no
    // other safe means.
    #[expect(
        clippy::as_conversions,
        clippy::cast_possible_truncation,
        reason = "a whole number within an i32's range converts exactly"
    )]
    let stored = signed as i32;
    stored
}

// A whole number outside an `i32`'s range wrapped modulo 2^32 into it, and 0
// for NaN and the infinities.
fn wrapped_int32(truncated: f64) -> f64 {
    if truncated.is_finite() {
        let modulo = truncated.rem_euclid(INT32_VALUE_COUNT);
        if modulo >= INT32_VALUE_COUNT_HALF {
            return modulo - INT32_VALUE_COUNT;
        }
        return modulo;
    }

    0.0
}

// A leg's duration as the JavaScript's `Int32Array` column of durations holds it.
fn stored_duration_s(duration_s: f64) -> f64 {
    f64::from(int32_of(duration_s))
}

impl Engine {
    /// The engine over `input`, whose connections are ordered by departure and
    /// whose walking links are ordered by the stop they leave, every stop below
    /// its stop count.
    #[must_use]
    #[track_caller]
    pub fn new(input: EngineInput) -> Self {
        let EngineInput {
            stop_count,
            connections,
            transfers,
            minimum_transfer_s,
        } = input;
        assert_stop_count(stop_count);
        assert_connections(&connections, stop_count);
        assert_transfers(&transfers, stop_count);
        let link_offsets = adjacency(&transfers.from_stop, stop_count);
        let incoming = incoming_adjacency(&transfers, stop_count);
        let (trip_slot, trip_count) = trip_slots(&connections.trip);
        Self {
            connections,
            trip_slot,
            trip_count,
            transfers,
            link_offsets,
            incoming,
            minimum_transfer_s,
        }
    }

    /// The engine's columns, borrowed for a query.
    #[must_use]
    pub fn view(&self) -> EngineView<'_> {
        EngineView {
            connections: ConnectionColumns {
                departure_s: &self.connections.departure_s,
                arrival_s: &self.connections.arrival_s,
                departure_stop: &self.connections.departure_stop,
                arrival_stop: &self.connections.arrival_stop,
                trip_slot: &self.trip_slot,
                boarding: &self.connections.boarding,
                alighting: &self.connections.alighting,
            },
            links: LinkColumns {
                offsets: &self.link_offsets,
                to_stop: &self.transfers.to_stop,
                duration_s: &self.transfers.duration_s,
            },
            incoming: IncomingLinkColumns {
                offsets: &self.incoming.offsets,
                from_stop: &self.incoming.from_stop,
                duration_s: &self.incoming.duration_s,
            },
            trip_count: self.trip_count,
            minimum_transfer_s: self.minimum_transfer_s,
        }
    }
}

// A stop's index is a `u32` in every column, so a stop count fits one.
#[track_caller]
fn assert_stop_count(stop_count: usize) {
    let is_stop_count = u32::try_from(stop_count).is_ok();
    assert::condition(is_stop_count, || {
        format!("routing engine: the stop count {stop_count} exceeds a u32")
    });
}

#[track_caller]
fn assert_stops(column: StopColumn<'_>, stop_count: usize) {
    for &stop in column.stops {
        assert::condition(index_of(stop) < stop_count, || {
            format!(
                "routing engine: {stop} in the {} column is not a stop of the snapshot",
                column.name
            )
        });
    }
}

// Each column, by its name, holds `count` values.
#[track_caller]
fn assert_lengths(columns: &[(&str, usize)], count: usize) {
    for &(name, length) in columns {
        assert::condition(length == count, || {
            format!("routing engine: the {name} column holds {length} values, not {count}")
        });
    }
}

#[track_caller]
fn assert_connections(connections: &Connections, stop_count: usize) {
    let count = connections.departure_s.len();
    let lengths = [
        ("arrival_s", connections.arrival_s.len()),
        ("departure_stop", connections.departure_stop.len()),
        ("arrival_stop", connections.arrival_stop.len()),
        ("trip", connections.trip.len()),
        ("sequence", connections.sequence.len()),
        ("boarding", connections.boarding.len()),
        ("alighting", connections.alighting.len()),
    ];
    assert_lengths(&lengths, count);
    assert::condition(u32::try_from(count).is_ok(), || {
        format!("routing engine: the connection count {count} exceeds a u32")
    });
    let is_ordered = connections.departure_s.is_sorted();
    assert::condition(is_ordered, || {
        "routing engine: the connections are not ordered by departure".to_owned()
    });
    let departure_stops = StopColumn {
        stops: &connections.departure_stop,
        name: "departure_stop",
    };
    assert_stops(departure_stops, stop_count);
    let arrival_stops = StopColumn {
        stops: &connections.arrival_stop,
        name: "arrival_stop",
    };
    assert_stops(arrival_stops, stop_count);
}

#[track_caller]
fn assert_transfers(transfers: &Transfers, stop_count: usize) {
    let count = transfers.from_stop.len();
    let lengths = [
        ("to_stop", transfers.to_stop.len()),
        ("duration_s", transfers.duration_s.len()),
    ];
    assert_lengths(&lengths, count);
    assert::condition(u32::try_from(count).is_ok(), || {
        format!("routing engine: the walking link count {count} exceeds a u32")
    });
    let is_ordered = transfers.from_stop.is_sorted();
    assert::condition(is_ordered, || {
        "routing engine: the walking links are not ordered by the stop they leave".to_owned()
    });
    let from_stops = StopColumn {
        stops: &transfers.from_stop,
        name: "from_stop",
    };
    assert_stops(from_stops, stop_count);
    let to_stops = StopColumn {
        stops: &transfers.to_stop,
        name: "to_stop",
    };
    assert_stops(to_stops, stop_count);
}

// The walking links of each stop, as offsets into link columns ordered by the
// stop `stops` names of each link: the stop it leaves, as the snapshot orders
// them, or the stop it reaches.
#[track_caller]
fn adjacency(stops: &[u32], stop_count: usize) -> Vec<u32> {
    let mut offsets = vec![0_u32; sum(stop_count, 1)];

    for &stop in stops {
        let slot = sum(index_of(stop), 1);
        let Some(offset) = offsets.get_mut(slot) else {
            assert::unreachable(
                &stop,
                "routing engine: a link's stop is below the stop count",
            );
        };
        let Some(counted) = offset.checked_add(1) else {
            assert::unreachable(&stop, "routing engine: a stop's link count fits a u32");
        };
        *offset = counted;
    }

    let mut total = 0_u32;

    for offset in &mut offsets {
        let Some(running) = total.checked_add(*offset) else {
            assert::unreachable(&total, "routing engine: the link count fits a u32");
        };
        total = running;
        *offset = running;
    }

    offsets
}

// The walking links into each stop, ordered by the stop they reach and each
// stop's links in the order the snapshot holds them, for a query that arrives
// by a time.
#[track_caller]
fn incoming_adjacency(transfers: &Transfers, stop_count: usize) -> IncomingLinks {
    let offsets = adjacency(&transfers.to_stop, stop_count);
    let link_count = transfers.to_stop.len();
    let mut from_stop = vec![0_u32; link_count];
    let mut duration_s = vec![0_u32; link_count];
    let mut filled = offsets.clone();
    let links = transfers
        .to_stop
        .iter()
        .zip(&transfers.from_stop)
        .zip(&transfers.duration_s);

    for ((&to_stop, &link_from), &link_s) in links {
        let Some(next_slot) = filled.get_mut(index_of(to_stop)) else {
            assert::unreachable(
                &to_stop,
                "routing engine: a link's stop is below the stop count",
            );
        };
        let slot = index_of(*next_slot);
        let from_slot = from_stop.get_mut(slot);
        let duration_slot = duration_s.get_mut(slot);
        let (Some(from_slot), Some(duration_slot)) = (from_slot, duration_slot) else {
            assert::unreachable(
                &slot,
                "routing engine: a link's slot is below the link count",
            );
        };
        *from_slot = link_from;
        *duration_slot = link_s;
        let Some(after) = next_slot.checked_add(1) else {
            assert::unreachable(&slot, "routing engine: the link count fits a u32");
        };
        *next_slot = after;
    }

    IncomingLinks {
        offsets,
        from_stop,
        duration_s,
    }
}

// Each connection's trip numbered from 0 in the order the trips first appear,
// and the count of trips, at most the count of connections.
#[track_caller]
fn trip_slots(trips: &[u32]) -> (Vec<u32>, usize) {
    let mut slots_by_trip: BTreeMap<u32, u32> = BTreeMap::new();
    let mut trip_slot = Vec::with_capacity(trips.len());

    for &trip in trips {
        let next = connection_number(slots_by_trip.len());
        let slot = *slots_by_trip.entry(trip).or_insert(next);
        trip_slot.push(slot);
    }

    (trip_slot, slots_by_trip.len())
}

// The shape a view's columns must hold for a query to index them: column
// lengths that agree, outgoing and incoming link offsets of one length that
// never decrease and end at their link counts, and a trip count bounded by the
// connections, since a query allocates by it.
#[track_caller]
fn assert_view(engine: &EngineView<'_>) {
    let offsets = engine.links.offsets;
    assert::condition(!offsets.is_empty(), || {
        "routing engine: the view holds no link offsets".to_owned()
    });
    assert_stop_count(engine.stop_count());
    let ConnectionColumns {
        departure_s,
        arrival_s,
        departure_stop,
        arrival_stop,
        trip_slot,
        boarding,
        alighting,
    } = engine.connections;
    let count = departure_s.len();
    let lengths = [
        ("arrival_s", arrival_s.len()),
        ("departure_stop", departure_stop.len()),
        ("arrival_stop", arrival_stop.len()),
        ("trip_slot", trip_slot.len()),
        ("boarding", boarding.len()),
        ("alighting", alighting.len()),
    ];
    assert_lengths(&lengths, count);
    assert::condition(u32::try_from(count).is_ok(), || {
        format!("routing engine: the connection count {count} exceeds a u32")
    });
    assert::condition(engine.trip_count <= count, || {
        format!(
            "routing engine: the trip count {} exceeds the {count} connections",
            engine.trip_count
        )
    });
    let link_count = engine.links.to_stop.len();
    assert_lengths(&[("duration_s", engine.links.duration_s.len())], link_count);
    let outgoing = OffsetColumn {
        offsets,
        name: "link",
    };
    assert_link_offsets(outgoing, link_count);
    let incoming = engine.incoming;
    let incoming_offset_count = incoming.offsets.len();
    assert::condition(incoming_offset_count == offsets.len(), || {
        format!(
            "routing engine: the view holds {incoming_offset_count} incoming link offsets, not {}",
            offsets.len()
        )
    });
    let incoming_count = incoming.from_stop.len();
    assert_lengths(
        &[("incoming_duration_s", incoming.duration_s.len())],
        incoming_count,
    );
    let incoming_offsets = OffsetColumn {
        offsets: incoming.offsets,
        name: "incoming link",
    };
    assert_link_offsets(incoming_offsets, incoming_count);
}

// A column of link offsets and the name a refusal gives its links.
#[derive(Debug, Clone, Copy)]
struct OffsetColumn<'column> {
    offsets: &'column [u32],
    name: &'static str,
}

// Offsets that never decrease and end at `link_count`.
#[track_caller]
fn assert_link_offsets(column: OffsetColumn<'_>, link_count: usize) {
    let OffsetColumn { offsets, name } = column;
    assert::condition(offsets.is_sorted(), || {
        format!("routing engine: the {name} offsets decrease")
    });
    let last = offsets.last().copied().map_or(0, index_of);
    assert::condition(last == link_count, || {
        format!(
            "routing engine: the last {name} offset {last} is not the {name} count {link_count}"
        )
    });
}

impl EngineView<'_> {
    /// The count of stops, one less than the link offsets.
    #[must_use]
    pub const fn stop_count(&self) -> usize {
        self.links.offsets.len().saturating_sub(1)
    }
}

impl<SetBy: Copy> Label<SetBy> {
    // A label holding `time_s` and `parent` at each of `stop_count` stops.
    fn filled(stop_count: usize, time_s: i32, parent: SetBy) -> Self {
        Self {
            time_s: vec![time_s; stop_count],
            parent: vec![parent; stop_count],
        }
    }

    #[track_caller]
    fn time_s(&self, stop: usize) -> f64 {
        f64::from(at(&self.time_s, stop))
    }

    // The time at `stop` as the label holds it.
    #[track_caller]
    fn stored_s(&self, stop: usize) -> i32 {
        at(&self.time_s, stop)
    }

    #[track_caller]
    fn parent(&self, stop: usize) -> SetBy {
        at(&self.parent, stop)
    }

    #[track_caller]
    fn slots(&mut self, stop: usize) -> (&mut i32, &mut SetBy) {
        let time = self.time_s.get_mut(stop);
        let parent = self.parent.get_mut(stop);
        let (Some(time), Some(parent)) = (time, parent) else {
            assert::unreachable(&stop, "routing engine: a stop a label improves is in it");
        };
        (time, parent)
    }

    // Sets the label at `step.stop` when `step.time_s` is earlier, with the leg
    // that reached it.
    #[track_caller]
    fn improve(&mut self, step: Step<SetBy>) {
        let (time, parent) = self.slots(step.stop);

        if step.time_s < f64::from(*time) {
            *time = int32_of(step.time_s);
            *parent = step.parent;
        }
    }

    // Sets the label at `step.stop` when `step.time_s` is later, with the leg
    // that leaves it.
    #[track_caller]
    fn improve_later(&mut self, step: Step<SetBy>) {
        let (time, parent) = self.slots(step.stop);

        if step.time_s > f64::from(*time) {
            *time = int32_of(step.time_s);
            *parent = step.parent;
        }
    }

    // Sets the time at `stop`, which the query starts from, with no leg.
    #[track_caller]
    fn start_at(&mut self, stop: usize, time_s: f64) {
        let Some(time) = self.time_s.get_mut(stop) else {
            assert::unreachable(
                &stop,
                "routing engine: a stop a query starts from is in a label",
            );
        };
        *time = int32_of(time_s);
    }
}

impl Round {
    fn unreached(stop_count: usize) -> Self {
        Self {
            arrival: Label::filled(stop_count, UNREACHED_S, Parent::None),
            ready: Label::filled(stop_count, UNREACHED_S, Parent::None),
            ride_arrival_s: vec![UNREACHED_S; stop_count],
        }
    }
}

impl RoundBack {
    fn unleft(stop_count: usize) -> Self {
        Self {
            depart: Label::filled(stop_count, UNLEFT_S, ParentBack::None),
            alight_by: Label::filled(stop_count, UNLEFT_S, ParentBack::None),
            boarded: Label::filled(stop_count, UNLEFT_S, ParentBack::None),
        }
    }
}

// Walks every link from `walk.stop`. A walk keeps the ride it follows, so
// reading it back never depends on a label a later walk overwrote.
#[track_caller]
fn walk_from(walk: WalkFrom<'_>) {
    let WalkFrom {
        engine,
        state,
        stop,
        arrival_s,
        ride,
    } = walk;
    let LinkColumns {
        offsets,
        to_stop,
        duration_s,
    } = engine.links;
    let first = index_of(at(offsets, stop));
    let end = index_of(at(offsets, sum(stop, 1)));

    for link in first..end {
        let link_s = at(duration_s, link);
        let parent = match ride {
            Some(ride) => Parent::WalkAfterRide {
                ride,
                duration_s: link_s,
            },
            None => Parent::WalkFromOrigin { duration_s: link_s },
        };
        let step = Step {
            stop: index_of(at(to_stop, link)),
            time_s: arrival_s + f64::from(link_s),
            parent,
        };
        state.arrival.improve(step);
        state.ready.improve(step);
    }
}

#[track_caller]
fn scan_round(scan: Scan<'_>) {
    let Scan {
        engine,
        previous,
        state,
        boarded_at,
        search,
        round,
    } = scan;
    let columns = engine.connections;
    let first = columns
        .departure_s
        .partition_point(|&departure_s| f64::from(departure_s) < search.departure_s);
    boarded_at.fill(None);

    for index in first..columns.departure_s.len() {
        let departure_s = f64::from(at(columns.departure_s, index));

        if departure_s >= state.arrival.time_s(search.target) {
            break;
        }

        let trip = index_of(at(columns.trip_slot, index));
        let Some(boarded) = boarded_at.get_mut(trip) else {
            assert::unreachable(&trip, "routing engine: a trip slot is below the trip count");
        };
        let departure_stop = index_of(at(columns.departure_stop, index));
        let is_boarding_stop = at(columns.boarding, index) == FLAG_SET;
        let is_boardable = is_boarding_stop && previous.ready.time_s(departure_stop) <= departure_s;
        let is_first_boarding = boarded.is_none() && is_boardable;

        if is_first_boarding {
            *boarded = Some(index);
        }

        let Some(board) = *boarded else {
            continue;
        };

        let is_alighting = at(columns.alighting, index) == FLAG_SET;

        if is_alighting {
            let arrival_stop = index_of(at(columns.arrival_stop, index));
            let arrival_s = f64::from(at(columns.arrival_s, index));
            let Some(ride_arrival_s) = state.ride_arrival_s.get_mut(arrival_stop) else {
                assert::unreachable(&arrival_stop, "routing engine: an arrival stop is a stop");
            };
            let is_earlier_ride = arrival_s < f64::from(*ride_arrival_s);

            if is_earlier_ride {
                *ride_arrival_s = int32_of(arrival_s);
                let ride = RideBy {
                    board: connection_number(board),
                    alight: connection_number(index),
                    round,
                };
                state.arrival.improve(Step {
                    stop: arrival_stop,
                    time_s: arrival_s,
                    parent: Parent::Ride { ride },
                });
                state.ready.improve(Step {
                    stop: arrival_stop,
                    time_s: arrival_s + engine.minimum_transfer_s,
                    parent: Parent::Ride { ride },
                });
                walk_from(WalkFrom {
                    engine,
                    state,
                    stop: arrival_stop,
                    arrival_s,
                    ride: Some(ride),
                });
            }
        }
    }
}

// Which label of a round the legs are read from: a round's arrival at the
// target, then the ready label of the round before at each boarding stop.
#[derive(Debug, Clone, Copy)]
enum LabelName {
    Arrival,
    Ready,
}

// The leg that ends the legs read back, the first of the journey, where
// `parent` is one: none, or a walk from the origin or the position.
#[track_caller]
fn first_leg(parent: Parent, stop: usize, search: Search<'_>) -> Option<Leg> {
    match parent {
        Parent::WalkFromOrigin { duration_s } => {
            let Checked::Stop(origin) = search.origin else {
                assert::unreachable(
                    &stop,
                    "routing engine: a walk from the origin leaves an origin stop",
                );
            };
            Some(Leg::Walk {
                from_stop: origin,
                to_stop: stop,
                duration_s: stored_duration_s(f64::from(duration_s)),
            })
        }
        Parent::WalkFromPosition { start } => {
            let Checked::Starts(starts) = search.origin else {
                assert::unreachable(
                    &stop,
                    "routing engine: a walk from the position reaches a start stop",
                );
            };
            Some(Leg::WalkFromPosition {
                to_stop: stop,
                duration_s: stored_duration_s(at(starts, start).walk_s),
            })
        }
        Parent::None | Parent::Ride { .. } | Parent::WalkAfterRide { .. } => None,
    }
}

// The legs of the journey that reaches the target in round `round_index`. A
// ride's boarding stop is read back through the ready label of the round
// before, which is what the scan boarded on.
#[track_caller]
fn legs(reading: Reading<'_>) -> Vec<Leg> {
    let columns = reading.engine.connections;
    let mut reversed = Vec::with_capacity(LEG_COUNT_MAX);
    let mut stop = reading.search.target;
    let mut current = reading.round_index;
    let mut label_name = LabelName::Arrival;

    for _ in 0..LEG_COUNT_MAX {
        let round = at_round(reading.rounds, current);
        let label = match label_name {
            LabelName::Arrival => &round.arrival,
            LabelName::Ready => &round.ready,
        };
        let parent = label.parent(stop);
        let (ride, walk_s) = match parent {
            Parent::Ride { ride } => (ride, None),
            Parent::WalkAfterRide { ride, duration_s } => (ride, Some(duration_s)),
            Parent::None | Parent::WalkFromOrigin { .. } | Parent::WalkFromPosition { .. } => {
                if let Some(leg) = first_leg(parent, stop, reading.search) {
                    reversed.push(leg);
                }
                reversed.reverse();
                return reversed;
            }
        };
        let board = index_of(ride.board);
        let alight = index_of(ride.alight);

        if let Some(duration_s) = walk_s {
            reversed.push(Leg::Walk {
                from_stop: index_of(at(columns.arrival_stop, alight)),
                to_stop: stop,
                duration_s: stored_duration_s(f64::from(duration_s)),
            });
        }

        reversed.push(Leg::Ride {
            board_connection: board,
            alight_connection: alight,
        });
        let Some(before) = usize::from(ride.round).checked_sub(1) else {
            assert::unreachable(
                &ride.round,
                "routing engine: a ride's round follows the origin's",
            );
        };
        current = before;
        stop = index_of(at(columns.departure_stop, board));
        label_name = LabelName::Ready;
    }

    assert::condition(false, || {
        "routing engine: a journey has more legs than its rounds allow".to_owned()
    });
    reversed
}

#[track_caller]
fn at_round<State>(rounds: &[State], index: usize) -> &State {
    let Some(round) = rounds.get(index) else {
        assert::unreachable(
            &index,
            "routing engine: a round read back is a round of the query",
        );
    };
    round
}

fn ride_count(journey_legs: &[Leg]) -> usize {
    let mut count = 0_usize;

    for leg in journey_legs {
        if leg.kind() == LegKind::Ride {
            count = sum(count, 1);
        }
    }

    count
}

// JavaScript's test of a stop: a whole number from 0 up to the stop count.
fn is_stop(engine: &EngineView<'_>, stop: f64) -> bool {
    let is_index = is_whole(stop) && stop >= 0.0;
    is_index && stop < number_of(engine.stop_count())
}

// The index of `stop`, a whole number `is_stop` admitted, which its decimal
// text reads back as.
#[track_caller]
fn stop_index(stop: f64) -> usize {
    let written = number_text(stop);
    let Ok(index) = written.parse::<usize>() else {
        assert::unreachable(&written, "routing engine: a checked stop is an index");
    };
    index
}

#[track_caller]
fn stop_origin_state(engine: &EngineView<'_>, departure: Departure<f64>) -> (Round, usize) {
    let stop = departure.from;
    assert::condition(is_stop(engine, stop), || {
        format!(
            "routing engine: the origin stop {} is not a stop of the snapshot",
            number_text(stop)
        )
    });
    let origin = stop_index(stop);
    let mut state = Round::unreached(engine.stop_count());
    state.arrival.start_at(origin, departure.departure_s);
    state.ready.start_at(origin, departure.departure_s);
    walk_from(WalkFrom {
        engine,
        state: &mut state,
        stop: origin,
        arrival_s: departure.departure_s,
        ride: None,
    });
    (state, origin)
}

#[track_caller]
fn assert_start(engine: &EngineView<'_>, start: Start) {
    assert::condition(is_stop(engine, start.stop), || {
        format!(
            "routing engine: the start stop {} is not a stop of the snapshot",
            number_text(start.stop)
        )
    });
    assert::condition(is_whole(start.walk_s), || {
        format!(
            "routing engine: a start stop's walk is not whole seconds: {}",
            number_text(start.walk_s)
        )
    });
    assert::condition(start.walk_s >= 0.0, || {
        format!(
            "routing engine: a start stop's walk is negative: {}",
            number_text(start.walk_s)
        )
    });
}

#[track_caller]
fn starts_origin_state(engine: &EngineView<'_>, departure: Departure<&[Start]>) -> Round {
    let starts = departure.from;
    assert::condition(!starts.is_empty(), || {
        "routing engine: a query from start stops names none".to_owned()
    });
    let mut state = Round::unreached(engine.stop_count());

    for (index, &start) in starts.iter().enumerate() {
        assert_start(engine, start);
        let step = Step {
            stop: stop_index(start.stop),
            time_s: departure.departure_s + start.walk_s,
            parent: Parent::WalkFromPosition { start: index },
        };
        state.arrival.improve(step);
        state.ready.improve(step);
    }

    state
}

// The labels of round 0, and the origin they start from, checked.
#[track_caller]
fn origin_state<'query>(
    engine: &EngineView<'_>,
    query: &Query<'query>,
) -> (Round, Checked<'query>) {
    match query.origin {
        Origin::Stop { stop } => {
            let departure = Departure {
                from: stop,
                departure_s: query.departure_s,
            };
            let (state, index) = stop_origin_state(engine, departure);
            (state, Checked::Stop(index))
        }
        Origin::Starts { starts } => {
            let departure = Departure {
                from: starts,
                departure_s: query.departure_s,
            };
            let state = starts_origin_state(engine, departure);
            (state, Checked::Starts(starts))
        }
        Origin::Unknown { kind } => {
            assert::unreachable(&kind, "routing engine: an origin of unknown kind")
        }
    }
}

/// The Pareto frontier of journeys from `query.origin` to `query.target`
/// leaving at or after `query.departure_s`, fewest changes first: each with
/// its arrival, its changes, and its legs.
///
/// The target and every stop of the origin must be a stop of the snapshot, and
/// the departure and every start's walk whole seconds, a walk at least 0.
#[must_use]
#[track_caller]
pub fn route(engine: &EngineView<'_>, query: &Query<'_>) -> Vec<Journey> {
    assert_view(engine);
    assert::condition(is_stop(engine, query.target), || {
        format!(
            "routing engine: the target {} is not a stop of the snapshot",
            number_text(query.target)
        )
    });
    assert::condition(is_whole(query.departure_s), || {
        format!(
            "routing engine: the departure is not whole seconds: {}",
            number_text(query.departure_s)
        )
    });
    let target = stop_index(query.target);
    let (origin_round, origin) = origin_state(engine, query);
    let search = Search {
        origin,
        target,
        departure_s: query.departure_s,
    };
    let mut best_s = origin_round.arrival.time_s(target);
    let mut rounds = Vec::with_capacity(sum(ROUNDS_MAX, 1));
    rounds.push(origin_round);
    let mut frontier = Vec::with_capacity(sum(ROUNDS_MAX, 1));
    let mut boarded_at = vec![None; engine.trip_count];

    if best_s < f64::from(UNREACHED_S) {
        let reading = Reading {
            engine,
            rounds: &rounds,
            search,
            round_index: 0,
        };
        frontier.push(Journey {
            arrival_s: best_s,
            changes: 0,
            legs: legs(reading),
        });
    }

    for round_index in 1..=ROUNDS_MAX {
        let Some(previous) = rounds.last() else {
            assert::unreachable(&round_index, "routing engine: a round follows the origin's");
        };
        let mut state = previous.clone();
        scan_round(Scan {
            engine,
            previous,
            state: &mut state,
            boarded_at: &mut boarded_at,
            search,
            round: round_number(round_index),
        });
        let arrival_s = state.arrival.time_s(target);
        rounds.push(state);

        if arrival_s < best_s {
            best_s = arrival_s;
            let reading = Reading {
                engine,
                rounds: &rounds,
                search,
                round_index,
            };
            let journey_legs = legs(reading);
            let changes = ride_count(&journey_legs).saturating_sub(1);
            frontier.push(Journey {
                arrival_s,
                changes,
                legs: journey_legs,
            });
        }
    }

    frontier
}

// Walks every link into `walk.stop`. A walk keeps the ride it comes before.
#[track_caller]
fn walk_into(walk: WalkInto<'_>) {
    let WalkInto {
        engine,
        state,
        stop,
        departure_s,
        ride,
    } = walk;
    let IncomingLinkColumns {
        offsets,
        from_stop,
        duration_s,
    } = engine.incoming;
    let first = index_of(at(offsets, stop));
    let end = index_of(at(offsets, sum(stop, 1)));

    for link in first..end {
        let link_s = at(duration_s, link);
        let parent = match ride {
            Some(ride) => ParentBack::WalkBeforeRide {
                ride,
                duration_s: link_s,
            },
            None => ParentBack::WalkToTarget { duration_s: link_s },
        };
        let step = Step {
            stop: index_of(at(from_stop, link)),
            time_s: departure_s - f64::from(link_s),
            parent,
        };
        state.depart.improve_later(step);
        state.alight_by.improve_later(step);
    }
}

impl SearchBack<'_> {
    // The shortest walk to a start stop, and 0 from an origin stop.
    const fn walk_s_min(&self) -> f64 {
        match self.origin {
            CheckedBack::Stop(_) => 0.0,
            CheckedBack::Starts { walk_s_min, .. } => walk_s_min,
        }
    }

    // The latest time the rider can leave the origin once a ride boards at
    // `boarding.from` at `boarding.departure_s`: the origin stop's own label,
    // or the boarding less the walk to it where it is a start stop.
    #[track_caller]
    fn left_origin_s(&self, state: &RoundBack, boarding: Departure<usize>) -> f64 {
        match &self.origin {
            CheckedBack::Stop(origin) => state.depart.time_s(*origin),
            CheckedBack::Starts { walk_s_by_stop, .. } => {
                let walk_s = at(walk_s_by_stop, boarding.from);
                if walk_s == NOT_A_START_S {
                    return f64::from(UNLEFT_S);
                }
                boarding.departure_s - f64::from(walk_s)
            }
        }
    }

    // The latest time the rider can leave the origin by the labels of `state`.
    #[track_caller]
    fn origin_left_s(&self, state: &RoundBack) -> f64 {
        match &self.origin {
            CheckedBack::Stop(origin) => state.depart.time_s(*origin),
            CheckedBack::Starts { starts, .. } => {
                let mut left_s = f64::from(UNLEFT_S);

                for start in *starts {
                    let stop = stop_index(start.stop);

                    if state.boarded.stored_s(stop) != UNLEFT_S {
                        left_s = left_s.max(state.boarded.time_s(stop) - start.walk_s);
                    }
                }

                left_s
            }
        }
    }
}

#[track_caller]
fn scan_round_back(scan: ScanBack<'_>) {
    let ScanBack {
        engine,
        previous,
        state,
        alighted_at,
        search,
        round,
    } = scan;
    let columns = engine.connections;
    let end = columns
        .departure_s
        .partition_point(|&departure_s| f64::from(departure_s) <= search.arrival_s);
    alighted_at.fill(None);
    let walk_s_min = search.walk_s_min();
    let mut best_s = search.origin_left_s(state);

    for index in (0..end).rev() {
        let departure_s = f64::from(at(columns.departure_s, index));

        if departure_s - walk_s_min <= best_s {
            break;
        }

        let trip = index_of(at(columns.trip_slot, index));
        let Some(alighted) = alighted_at.get_mut(trip) else {
            assert::unreachable(&trip, "routing engine: a trip slot is below the trip count");
        };
        let arrival_stop = index_of(at(columns.arrival_stop, index));
        let is_alighting_stop = at(columns.alighting, index) == FLAG_SET;
        let arrival_s = f64::from(at(columns.arrival_s, index));
        let is_alightable =
            is_alighting_stop && arrival_s <= previous.alight_by.time_s(arrival_stop);
        let is_last_alighting = alighted.is_none() && is_alightable;

        if is_last_alighting {
            *alighted = Some(index);
        }

        let Some(alight) = *alighted else {
            continue;
        };

        let is_boarding = at(columns.boarding, index) == FLAG_SET;

        if is_boarding {
            let departure_stop = index_of(at(columns.departure_stop, index));
            let ride = RideBy {
                board: connection_number(index),
                alight: connection_number(alight),
                round,
            };

            if departure_s > state.boarded.time_s(departure_stop) {
                let boarding = Step {
                    stop: departure_stop,
                    time_s: departure_s,
                    parent: ParentBack::Ride { ride },
                };
                state.boarded.improve_later(boarding);
                state.depart.improve_later(boarding);
                state.alight_by.improve_later(Step {
                    time_s: departure_s - engine.minimum_transfer_s,
                    ..boarding
                });
                walk_into(WalkInto {
                    engine,
                    state,
                    stop: departure_stop,
                    departure_s,
                    ride: Some(ride),
                });
            }

            let boarding = Departure {
                from: departure_stop,
                departure_s,
            };
            best_s = best_s.max(search.left_origin_s(state, boarding));
        }
    }
}

// Which label of a round the legs of a query arriving by a time are read
// from: the origin stop's departure or a start stop's boarding, then the
// alighting label of the round before at each stop a ride alights at.
#[derive(Debug, Clone, Copy)]
enum LabelBackName {
    Depart,
    AlightBy,
    Boarded,
}

// A stop and the label its legs are read back from.
#[derive(Debug, Clone, Copy)]
struct LabelAt {
    stop: usize,
    name: LabelBackName,
}

// The legs from `from.stop`, read from its label `from.name` of the round
// read, to the target. A ride's alighting stop is read back through the alighting label of
// the round before, which is what the scan alighted on.
#[track_caller]
fn legs_back(reading: ReadingBack<'_>, from: LabelAt) -> Vec<Leg> {
    let columns = reading.engine.connections;
    let target = reading.search.target;
    let mut result = Vec::with_capacity(LEG_COUNT_MAX);
    let mut current = reading.round_index;
    let LabelAt { mut stop, mut name } = from;

    for _ in 0..LEG_COUNT_MAX {
        let round = at_round(reading.rounds, current);
        let label = match name {
            LabelBackName::Depart => &round.depart,
            LabelBackName::AlightBy => &round.alight_by,
            LabelBackName::Boarded => &round.boarded,
        };
        let (ride, walk_s) = match label.parent(stop) {
            ParentBack::None => {
                assert::condition(stop == target, || {
                    format!(
                        "routing engine: a journey arriving by a time ends at {stop}, not the target {target}"
                    )
                });
                return result;
            }
            ParentBack::WalkToTarget { duration_s } => {
                result.push(Leg::Walk {
                    from_stop: stop,
                    to_stop: target,
                    duration_s: stored_duration_s(f64::from(duration_s)),
                });
                return result;
            }
            ParentBack::Ride { ride } => (ride, None),
            ParentBack::WalkBeforeRide { ride, duration_s } => (ride, Some(duration_s)),
        };
        let board = index_of(ride.board);
        let alight = index_of(ride.alight);

        if let Some(duration_s) = walk_s {
            result.push(Leg::Walk {
                from_stop: stop,
                to_stop: index_of(at(columns.departure_stop, board)),
                duration_s: stored_duration_s(f64::from(duration_s)),
            });
        }

        result.push(Leg::Ride {
            board_connection: board,
            alight_connection: alight,
        });
        let Some(before) = usize::from(ride.round).checked_sub(1) else {
            assert::unreachable(
                &ride.round,
                "routing engine: a ride's round follows the target's",
            );
        };
        current = before;
        stop = index_of(at(columns.arrival_stop, alight));
        name = LabelBackName::AlightBy;
    }

    assert::condition(false, || {
        "routing engine: a journey arriving by a time has more legs than its rounds allow"
            .to_owned()
    });
    result
}

// The time a journey leaving at `leaving.departure_s` along `leaving.legs`
// arrives.
#[track_caller]
fn arrival_along(arrival_s: &[i32], leaving: &Leaving) -> f64 {
    let mut time_s = leaving.departure_s;

    for leg in &leaving.legs {
        match *leg {
            Leg::Ride {
                alight_connection, ..
            } => time_s = f64::from(at(arrival_s, alight_connection)),
            Leg::Walk { duration_s, .. } | Leg::WalkFromPosition { duration_s, .. } => {
                time_s += duration_s;
            }
        }
    }

    time_s
}

// The latest departure from the origin of the round read and its legs, or that
// the origin cannot be left in time: from start stops, the latest of their
// boardings less the walk to each, the first in the query's order on a tie.
#[track_caller]
fn origin_journey(reading: ReadingBack<'_>) -> OriginJourney {
    let state = at_round(reading.rounds, reading.round_index);

    match &reading.search.origin {
        CheckedBack::Stop(origin) => {
            if state.depart.stored_s(*origin) == UNLEFT_S {
                return OriginJourney::Unleft;
            }

            let legs = legs_back(
                reading,
                LabelAt {
                    stop: *origin,
                    name: LabelBackName::Depart,
                },
            );
            OriginJourney::Left(Leaving {
                departure_s: state.depart.time_s(*origin),
                legs,
            })
        }
        CheckedBack::Starts { starts, .. } => {
            let mut chosen_s = f64::from(UNLEFT_S);
            let mut chosen = None;

            for &start in *starts {
                let stop = stop_index(start.stop);
                let is_boarded = state.boarded.stored_s(stop) != UNLEFT_S;
                let left_s = state.boarded.time_s(stop) - start.walk_s;
                let is_later = is_boarded && left_s > chosen_s;

                if is_later {
                    chosen_s = left_s;
                    chosen = Some((start, stop));
                }
            }

            let Some((start, stop)) = chosen else {
                return OriginJourney::Unleft;
            };
            let rest = legs_back(
                reading,
                LabelAt {
                    stop,
                    name: LabelBackName::Boarded,
                },
            );
            let mut legs = Vec::with_capacity(sum(rest.len(), 1));
            // The walk is the query's own, whole, as the JavaScript's leg
            // carries it, where a leaving query's walk reads back through a
            // column of `ToInt32` durations.
            legs.push(Leg::WalkFromPosition {
                to_stop: stop,
                duration_s: start.walk_s,
            });
            legs.extend(rest);
            OriginJourney::Left(Leaving {
                departure_s: chosen_s,
                legs,
            })
        }
    }
}

// The labels of round 0: the target reached by the time, and every stop a
// walk reaches the target from.
#[track_caller]
fn target_state(engine: &EngineView<'_>, search: &SearchBack<'_>) -> RoundBack {
    let mut state = RoundBack::unleft(engine.stop_count());
    state.depart.start_at(search.target, search.arrival_s);
    state.alight_by.start_at(search.target, search.arrival_s);
    state.boarded.start_at(search.target, search.arrival_s);
    walk_into(WalkInto {
        engine,
        state: &mut state,
        stop: search.target,
        departure_s: search.arrival_s,
        ride: None,
    });
    state
}

// The origin of a query arriving by a time, checked, with its start stops'
// walks by stop and the shortest of them.
#[track_caller]
fn checked_back<'query>(engine: &EngineView<'_>, origin: Origin<'query>) -> CheckedBack<'query> {
    match origin {
        Origin::Stop { stop } => {
            assert::condition(is_stop(engine, stop), || {
                format!(
                    "routing engine: the origin stop {} is not a stop of the snapshot",
                    number_text(stop)
                )
            });
            CheckedBack::Stop(stop_index(stop))
        }
        Origin::Starts { starts } => {
            assert::condition(!starts.is_empty(), || {
                "routing engine: a query from start stops names none".to_owned()
            });
            let mut walk_s_by_stop = vec![NOT_A_START_S; engine.stop_count()];
            let mut walk_s_min = f64::from(UNREACHED_S);

            for &start in starts {
                assert_start(engine, start);
                let Some(walk_s) = walk_s_by_stop.get_mut(stop_index(start.stop)) else {
                    assert::unreachable(&start.stop, "routing engine: a checked stop is a stop");
                };
                assert::condition(*walk_s == NOT_A_START_S, || {
                    format!(
                        "routing engine: the start stop {} is named twice",
                        number_text(start.stop)
                    )
                });
                *walk_s = int32_of(start.walk_s);
                walk_s_min = walk_s_min.min(start.walk_s);
            }

            CheckedBack::Starts {
                starts,
                walk_s_by_stop,
                walk_s_min,
            }
        }
        Origin::Unknown { kind } => {
            assert::unreachable(&kind, "routing engine: an origin of unknown kind")
        }
    }
}

/// The Pareto frontier of journeys from `query.origin` to `query.target`
/// arriving at or before `query.arrival_s`, fewest changes first.
///
/// Each journey holds the latest time it leaves the origin, its arrival, its
/// changes, and its legs. The target and every stop of the origin must be a
/// stop of the snapshot, the arrival and every start's walk whole seconds, a
/// walk at least 0, and no start stop named twice.
#[must_use]
#[track_caller]
pub fn route_arriving_by(
    engine: &EngineView<'_>,
    query: &QueryArrivingBy<'_>,
) -> Vec<JourneyArrivingBy> {
    assert_view(engine);
    assert::condition(is_stop(engine, query.target), || {
        format!(
            "routing engine: the target {} is not a stop of the snapshot",
            number_text(query.target)
        )
    });
    assert::condition(is_whole(query.arrival_s), || {
        format!(
            "routing engine: the arrival is not whole seconds: {}",
            number_text(query.arrival_s)
        )
    });
    let search = SearchBack {
        origin: checked_back(engine, query.origin),
        target: stop_index(query.target),
        arrival_s: query.arrival_s,
    };
    let mut rounds = Vec::with_capacity(sum(ROUNDS_MAX, 1));
    rounds.push(target_state(engine, &search));
    let mut frontier = Vec::with_capacity(sum(ROUNDS_MAX, 1));
    let mut alighted_at = vec![None; engine.trip_count];
    let mut best_s = f64::from(UNLEFT_S);

    for round_index in 0..=ROUNDS_MAX {
        if round_index > 0 {
            let Some(previous) = rounds.last() else {
                assert::unreachable(&round_index, "routing engine: a round follows the target's");
            };
            let mut state = previous.clone();
            scan_round_back(ScanBack {
                engine,
                previous,
                state: &mut state,
                alighted_at: &mut alighted_at,
                search: &search,
                round: round_number(round_index),
            });
            rounds.push(state);
        }

        let reading = ReadingBack {
            engine,
            rounds: &rounds,
            search: &search,
            round_index,
        };
        let OriginJourney::Left(leaving) = origin_journey(reading) else {
            continue;
        };

        if leaving.departure_s > best_s {
            best_s = leaving.departure_s;
            let arrival_s = arrival_along(engine.connections.arrival_s, &leaving);
            assert::condition(arrival_s <= query.arrival_s, || {
                format!(
                    "routing engine: a journey arrives at {}, after {}",
                    number_text(arrival_s),
                    number_text(query.arrival_s)
                )
            });
            let changes = ride_count(&leaving.legs).saturating_sub(1);
            frontier.push(JourneyArrivingBy {
                departure_s: leaving.departure_s,
                arrival_s,
                changes,
                legs: leaving.legs,
            });
        }
    }

    frontier
}
