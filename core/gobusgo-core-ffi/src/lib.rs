//! The core's binding for Swift and Kotlin. Each export converts its arguments
//! and result across uniffi and holds no logic of its own. The core takes no
//! crate and so derives none of uniffi's traits: a `#[uniffi::remote]` item here
//! restates a type of the core, which uniffi then passes as that type, and the
//! compiler refuses a restatement whose fields differ from the core's. A record
//! declared here with a derive is one the core has no owned type for.
//!
//! A failed assertion of the core aborts the app, as the release profile aborts
//! on every panic: an assertion's failure is a programmer error, and a native
//! caller handles none.
//!
//! `RoutingEngine` is the one object this binding holds state in: the engine
//! it owns, built once, which each query borrows. A record crosses by being
//! serialized on every call, a copy each way for a record as large as an
//! engine, and a failure aborts the app, so no object outlives a failure.

use gobusgo_core::math::angles::{self, Turn};
use gobusgo_core::math::checks;
use gobusgo_core::math::geodesy::{self, Between, PlaneCoverage, Position, TangentPlane};
use gobusgo_core::math::interpolation::{self, Clamp, Lerp};
use gobusgo_core::routing_engine;
use gobusgo_core::routing_snapshot::{self, Connections, Transfers, Trip};
use gobusgo_core::routing_walk::{self, ReachedStop, WalkBasis, WalkRules};
use gobusgo_core::trip_path;

// The names Swift and Kotlin know these types by, where the core's own name is
// another.
type SnapshotRefusal = routing_snapshot::RefusalReason;
type SnapshotPositions = routing_snapshot::Positions;
type PathPoint = trip_path::Point;
type PathStop = trip_path::Stop;
type WalkStart = routing_walk::Start;
type WalkCandidate = routing_walk::Candidate;

uniffi::setup_scaffolding!();

/// The version of the core this library was built from.
#[uniffi::export]
#[must_use]
pub fn core_version() -> String {
    gobusgo_core::core_version().to_owned()
}

/// A pair of numbers that must be in order, and the label that names them.
#[derive(Debug, Clone, uniffi::Record)]
pub struct Ordered {
    pub low: f64,
    pub high: f64,
    pub label: String,
}

/// Two compass directions in degrees, the one turned from and the one turned to.
#[uniffi::remote(Record)]
pub struct Turn {
    pub from: f64,
    pub to: f64,
}

/// A line from `from` to `to`, and the share of the way along it to go.
#[uniffi::remote(Record)]
pub struct Lerp {
    pub from: f64,
    pub to: f64,
    pub fraction: f64,
}

/// A value and the bounds to bring it inside, both included.
#[uniffi::remote(Record)]
pub struct Clamp {
    pub value: f64,
    pub min: f64,
    pub max: f64,
}

/// A position on the Earth, in degrees.
#[uniffi::remote(Record)]
pub struct Position {
    pub lon: f64,
    pub lat: f64,
}

/// Two positions, the one a measure starts from and the one it ends at.
#[uniffi::remote(Record)]
pub struct Between {
    pub source: Position,
    pub target: Position,
}

/// A plane tangent at a latitude, with the meters of a degree of longitude on it.
#[uniffi::remote(Record)]
pub struct TangentPlane {
    pub reference_latitude_degrees: f64,
    pub meters_per_degree_lon: f64,
}

/// A plane and the span of latitudes it must measure.
#[uniffi::remote(Record)]
pub struct PlaneCoverage {
    pub plane: TangentPlane,
    pub latitude_degrees_min: f64,
    pub latitude_degrees_max: f64,
}

/// Asserts that `value` is a finite number; `label` names it in a failure.
#[uniffi::export]
pub fn assert_finite(value: f64, label: &str) {
    checks::assert_finite(value, label);
}

/// Asserts that `low` is at most `high`.
#[uniffi::export]
pub fn assert_ordered(ordered: Ordered) {
    let Ordered { low, high, label } = ordered;
    checks::assert_ordered(checks::Ordered {
        low,
        high,
        label: &label,
    });
}

/// The degrees of a whole turn.
#[uniffi::export]
#[must_use]
pub const fn degrees_per_turn() -> f64 {
    angles::DEGREES_PER_TURN
}

/// The degrees of a half turn, which is π radians.
#[uniffi::export]
#[must_use]
pub const fn degrees_per_half_turn() -> f64 {
    angles::DEGREES_PER_HALF_TURN
}

/// `degrees` in radians.
#[uniffi::export]
#[must_use]
pub fn radians(degrees: f64) -> f64 {
    angles::radians(degrees)
}

/// `radians` in degrees.
#[uniffi::export]
#[must_use]
pub fn degrees(radians: f64) -> f64 {
    angles::degrees(radians)
}

/// `degrees` turned into the range from 0 up to, and not including, 360.
#[uniffi::export]
#[must_use]
pub fn normalized_degrees(degrees: f64) -> f64 {
    angles::normalized_degrees(degrees)
}

/// The smaller angle between two directions, from 0 to 180 degrees.
#[uniffi::export]
#[must_use]
pub fn turn_degrees(turn: Turn) -> f64 {
    angles::turn_degrees(turn)
}

/// The mean radius of the Earth in meters.
#[uniffi::export]
#[must_use]
pub const fn earth_radius_meters() -> f64 {
    geodesy::EARTH_RADIUS_METERS
}

/// The meters of a degree of latitude, and of a degree of longitude at the equator.
#[uniffi::export]
#[must_use]
pub const fn meters_per_degree() -> f64 {
    geodesy::METERS_PER_DEGREE
}

/// The most a tangent plane's longitude scale may be off at a latitude it covers.
#[uniffi::export]
#[must_use]
pub const fn plane_scale_error_max() -> f64 {
    geodesy::PLANE_SCALE_ERROR_MAX
}

/// The position `coordinates` hold, a longitude and a latitude in degrees.
#[uniffi::export]
#[must_use]
pub fn assert_position(coordinates: &[f64], label: &str) -> Position {
    geodesy::assert_position(coordinates, label)
}

/// The great-circle distance in meters between two positions.
#[uniffi::export]
#[must_use]
pub fn distance_meters(between: Between) -> f64 {
    geodesy::distance_meters(between)
}

/// The initial great-circle bearing between two positions, in degrees from north.
#[uniffi::export]
#[must_use]
pub fn initial_bearing_degrees(between: Between) -> f64 {
    geodesy::initial_bearing_degrees(between)
}

/// The meters of a degree of longitude at `latitude_degrees`.
#[uniffi::export]
#[must_use]
pub fn meters_per_degree_longitude(latitude_degrees: f64) -> f64 {
    geodesy::meters_per_degree_longitude(latitude_degrees)
}

/// The plane tangent at `reference_latitude_degrees`.
#[uniffi::export]
#[must_use]
pub fn tangent_plane(reference_latitude_degrees: f64) -> TangentPlane {
    geodesy::tangent_plane(reference_latitude_degrees)
}

/// Asserts that a plane measures every latitude of a span closely enough.
#[uniffi::export]
pub fn assert_plane_covers(coverage: PlaneCoverage) {
    geodesy::assert_plane_covers(coverage);
}

/// The value `fraction` of the way from `from` to `to`.
#[uniffi::export]
#[must_use]
pub fn lerp(line: Lerp) -> f64 {
    interpolation::lerp(line)
}

/// `value` brought inside `min` and `max`, both included.
#[uniffi::export]
#[must_use]
pub fn clamp(bounds: Clamp) -> f64 {
    interpolation::clamp(bounds)
}

/// Why a routing snapshot file was refused.
#[uniffi::remote(Enum)]
pub enum SnapshotRefusal {
    InvalidHeader,
    UnsupportedVersion,
    InvalidLength,
    InvalidText,
    InvalidPosition,
}

/// A trip of a trips file.
#[uniffi::remote(Record)]
pub struct Trip {
    pub id: String,
    pub route_id: String,
    pub service_day_offset: u8,
}

/// The walking links of a transfers file, by column.
#[uniffi::remote(Record)]
pub struct Transfers {
    pub from_stop: Vec<u32>,
    pub to_stop: Vec<u32>,
    pub duration_s: Vec<u32>,
}

/// The connections of a connections file in departure order, by column.
#[uniffi::remote(Record)]
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

/// The stop positions of a positions file, in microdegrees by axis.
#[uniffi::remote(Record)]
pub struct SnapshotPositions {
    pub lat_microdegrees: Vec<i32>,
    pub lon_microdegrees: Vec<i32>,
}

/// The outcome of decoding a stops file.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum StopsOutcome {
    Decoded { stop_ids: Vec<String> },
    Refused { reason: SnapshotRefusal },
}

/// The outcome of decoding a trips file.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum TripsOutcome {
    Decoded { trips: Vec<Trip> },
    Refused { reason: SnapshotRefusal },
}

/// The outcome of decoding a transfers file.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum TransfersOutcome {
    Decoded { transfers: Transfers },
    Refused { reason: SnapshotRefusal },
}

/// The outcome of decoding a connections file.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum ConnectionsOutcome {
    Decoded { connections: Connections },
    Refused { reason: SnapshotRefusal },
}

/// The outcome of decoding a positions file.
#[derive(Debug, Clone, PartialEq, Eq, uniffi::Enum)]
pub enum PositionsOutcome {
    Decoded { positions: SnapshotPositions },
    Refused { reason: SnapshotRefusal },
}

/// The format version of the routing snapshot files this library reads.
#[uniffi::export]
#[must_use]
pub const fn routing_snapshot_format_version() -> u16 {
    routing_snapshot::FORMAT_VERSION
}

/// The microdegrees a positions file holds on both axes for a stop with no known position.
#[uniffi::export]
#[must_use]
pub const fn position_unknown_microdegrees() -> i32 {
    routing_snapshot::POSITION_UNKNOWN_MICRODEGREES
}

/// The stop identifiers of a stops file, a stop's index being its position.
#[uniffi::export]
#[must_use]
pub fn decode_stops(bytes: &[u8]) -> StopsOutcome {
    match routing_snapshot::decode_stops(bytes) {
        Ok(stop_ids) => StopsOutcome::Decoded { stop_ids },
        Err(reason) => StopsOutcome::Refused { reason },
    }
}

/// The trips of a trips file.
#[uniffi::export]
#[must_use]
pub fn decode_trips(bytes: &[u8]) -> TripsOutcome {
    match routing_snapshot::decode_trips(bytes) {
        Ok(trips) => TripsOutcome::Decoded { trips },
        Err(reason) => TripsOutcome::Refused { reason },
    }
}

/// The walking links of a transfers file.
#[uniffi::export]
#[must_use]
pub fn decode_transfers(bytes: &[u8]) -> TransfersOutcome {
    match routing_snapshot::decode_transfers(bytes) {
        Ok(transfers) => TransfersOutcome::Decoded { transfers },
        Err(reason) => TransfersOutcome::Refused { reason },
    }
}

/// The connections of a connections file.
#[uniffi::export]
#[must_use]
pub fn decode_connections(bytes: &[u8]) -> ConnectionsOutcome {
    match routing_snapshot::decode_connections(bytes) {
        Ok(connections) => ConnectionsOutcome::Decoded { connections },
        Err(reason) => ConnectionsOutcome::Refused { reason },
    }
}

/// The stop positions of a positions file.
#[uniffi::export]
#[must_use]
pub fn decode_positions(bytes: &[u8]) -> PositionsOutcome {
    match routing_snapshot::decode_positions(bytes) {
        Ok(positions) => PositionsOutcome::Decoded { positions },
        Err(reason) => PositionsOutcome::Refused { reason },
    }
}

/// A point of a path in degrees.
#[uniffi::remote(Record)]
pub struct PathPoint {
    pub longitude: f64,
    pub latitude: f64,
}

/// A stop of a path: its distance along the points in meters, and its
/// scheduled arrival and departure in seconds from the start of the service day.
#[uniffi::remote(Record)]
pub struct PathStop {
    pub distance_meters: f64,
    pub arrival_seconds: f64,
    pub departure_seconds: f64,
}

/// One path as the event carries it.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct EncodedPath {
    pub trip_id: String,
    pub route_id: String,
    pub service_date_ms: f64,
    pub points: String,
    pub stops: String,
}

/// A decoded path, held under `key`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct TripPath {
    pub trip_id: String,
    pub route_id: String,
    pub service_date_ms: f64,
    pub key: String,
    pub points: Vec<PathPoint>,
    pub stops: Vec<PathStop>,
}

/// The most paths a cache holds.
#[uniffi::export]
#[must_use]
pub fn trip_path_count_max() -> u64 {
    let Ok(count_max) = u64::try_from(trip_path::TRIP_PATH_COUNT_MAX) else {
        gobusgo_core::assert::unreachable(
            &trip_path::TRIP_PATH_COUNT_MAX,
            "binding: the cache's bound fits a u64",
        );
    };
    count_max
}

/// The key a path is held under.
#[uniffi::export]
#[must_use]
pub fn trip_path_key(trip_id: &str, service_date_ms: f64) -> String {
    trip_path::trip_path_key(trip_path::KeyOf {
        trip_id,
        service_date_ms,
    })
}

/// One encoded path, decoded.
#[uniffi::export]
#[must_use]
pub fn decode_trip_path(path: EncodedPath) -> TripPath {
    let decoded = trip_path::decode_trip_path(trip_path::EncodedPath {
        trip_id: &path.trip_id,
        service_date_ms: path.service_date_ms,
        points: &path.points,
        stops: &path.stops,
    });
    TripPath {
        trip_id: path.trip_id,
        route_id: path.route_id,
        service_date_ms: path.service_date_ms,
        key: decoded.key,
        points: decoded.points,
        stops: decoded.stops,
    }
}

/// A cache of `cache`'s paths and `paths`, at most `trip_path_count_max()` of
/// them: a path put again moves to the back, and the paths put earliest leave first.
#[uniffi::export]
#[must_use]
pub fn with_trip_paths(cache: Vec<TripPath>, paths: Vec<TripPath>) -> Vec<TripPath> {
    let keyed = |path: TripPath| (path.key.clone(), path);
    let held = cache.into_iter().map(keyed).collect();
    let put = paths.into_iter().map(keyed).collect();
    let next = trip_path::with_trip_paths(held, put);
    next.into_iter().map(|(_, path)| path).collect()
}

/// How a snapshot's walking links are measured.
#[uniffi::remote(Enum)]
pub enum WalkBasis {
    Straight,
    Streets,
    Mixed,
}

/// The walking rules of a manifest entry's `transferRules`.
#[uniffi::remote(Record)]
pub struct WalkRules {
    pub walk_radius_m: f64,
    pub walk_speed_m_per_s: f64,
    pub walk_link_count_per_stop_max: f64,
}

/// A start stop and the whole seconds of the walk to it.
#[uniffi::remote(Record)]
pub struct WalkStart {
    pub stop: f64,
    pub walk_s: f64,
}

/// A stop a walk over the streets searches for, and its position in degrees.
#[uniffi::remote(Record)]
pub struct WalkCandidate {
    pub stop: f64,
    pub lat: f64,
    pub lon: f64,
}

/// A stop a walk over the streets reached, and the meters of street to it.
#[uniffi::remote(Record)]
pub struct ReachedStop {
    pub stop: f64,
    pub street_m: f64,
}

/// A rider's position, the stop positions of a positions file, and the walking
/// rules a walk from the position follows.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Near {
    pub position: Position,
    pub positions: SnapshotPositions,
    pub rules: WalkRules,
}

impl Near {
    const fn query(&self) -> routing_walk::Near<'_> {
        routing_walk::Near {
            position: self.position,
            positions: &self.positions,
            rules: self.rules,
        }
    }
}

/// The most candidates a walk from a position over the streets searches for.
#[uniffi::export]
#[must_use]
pub fn walk_candidate_count_max() -> u64 {
    let Ok(count_max) = u64::try_from(routing_walk::WALK_CANDIDATE_COUNT_MAX) else {
        gobusgo_core::assert::unreachable(
            &routing_walk::WALK_CANDIDATE_COUNT_MAX,
            "binding: the candidates' bound fits a u64",
        );
    };
    count_max
}

/// The basis of a manifest entry's `transferRules`, from its `walkBasis`
/// where that is text and its `walkStreetMetersMax` where it holds one.
#[uniffi::export]
#[must_use]
#[expect(
    clippy::needless_pass_by_value,
    reason = "uniffi lifts an optional text only as an owned String"
)]
pub fn walk_basis_of(walk_basis: Option<String>, walk_street_meters_max: Option<f64>) -> WalkBasis {
    routing_walk::walk_basis_of(walk_basis.as_deref(), walk_street_meters_max)
}

/// Whether a walk from a position or to a point is planned along the streets.
#[uniffi::export]
#[must_use]
pub const fn is_street_walk(basis: WalkBasis) -> bool {
    routing_walk::is_street_walk(basis)
}

/// The street length, in meters, that a walk over the streets may have.
#[uniffi::export]
#[must_use]
pub fn street_meters_max_of(walk_street_meters_max: Option<f64>) -> f64 {
    routing_walk::street_meters_max_of(walk_street_meters_max)
}

/// The start stops within walking distance of a position, nearest first.
#[uniffi::export]
#[must_use]
pub fn starts_near(near: &Near) -> Vec<WalkStart> {
    routing_walk::starts_near(&near.query())
}

/// The stops a walk from a position over the streets searches among.
#[uniffi::export]
#[must_use]
pub fn walk_candidates_near(near: &Near) -> Vec<WalkCandidate> {
    routing_walk::walk_candidates_near(&near.query())
}

/// The start stops of a walk over the streets, nearest by street first.
#[uniffi::export]
#[must_use]
pub fn starts_from_streets(stops: &[ReachedStop], rules: WalkRules) -> Vec<WalkStart> {
    routing_walk::starts_from_streets(stops, rules)
}

/// The most rides a journey takes.
#[uniffi::export]
#[must_use]
pub fn rounds_max() -> u64 {
    let Ok(rounds) = u64::try_from(routing_engine::ROUNDS_MAX) else {
        gobusgo_core::assert::unreachable(
            &routing_engine::ROUNDS_MAX,
            "binding: the rounds' bound fits a u64",
        );
    };
    rounds
}

/// A snapshot's stop count, connections ordered by departure, walking links
/// ordered by the stop they leave, and minimum transfer in seconds.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct EngineInput {
    pub stop_count: u32,
    pub connections: Connections,
    pub transfers: Transfers,
    pub minimum_transfer_s: f64,
}

/// A query's origin: one stop, or start stops each with the whole seconds of
/// its walk from the rider's position.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum Origin {
    Stop { stop: f64 },
    Starts { starts: Vec<WalkStart> },
}

impl Origin {
    fn query(&self) -> routing_engine::Origin<'_> {
        match self {
            Self::Stop { stop } => routing_engine::Origin::Stop { stop: *stop },
            Self::Starts { starts } => routing_engine::Origin::Starts { starts },
        }
    }
}

/// A query leaving `origin` for the stop `target` at or after `departure_s`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Query {
    pub origin: Origin,
    pub target: f64,
    pub departure_s: f64,
}

/// A query from `origin` to the stop `target` arriving at or before
/// `arrival_s`.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct QueryArrivingBy {
    pub origin: Origin,
    pub target: f64,
    pub arrival_s: f64,
}

/// A leg of a journey: a ride from one connection to another, a walking link
/// between two stops, or the walk from the rider's position to a start stop.
#[derive(Debug, Clone, PartialEq, uniffi::Enum)]
pub enum Leg {
    Ride {
        board_connection: u32,
        alight_connection: u32,
    },
    Walk {
        from_stop: u32,
        to_stop: u32,
        duration_s: f64,
    },
    WalkFromPosition {
        to_stop: u32,
        duration_s: f64,
    },
}

/// A journey of a frontier: its arrival, its changes, and its legs.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct Journey {
    pub arrival_s: f64,
    pub changes: u32,
    pub legs: Vec<Leg>,
}

/// A journey of a frontier arriving by a time: the latest time it leaves the
/// origin, its arrival, its changes, and its legs.
#[derive(Debug, Clone, PartialEq, uniffi::Record)]
pub struct JourneyArrivingBy {
    pub departure_s: f64,
    pub arrival_s: f64,
    pub changes: u32,
    pub legs: Vec<Leg>,
}

/// An engine over a snapshot, built once from its columns.
#[derive(Debug, uniffi::Object)]
pub struct RoutingEngine {
    engine: routing_engine::Engine,
}

#[uniffi::export]
impl RoutingEngine {
    /// The engine over `input`.
    #[uniffi::constructor]
    #[must_use]
    pub fn new(input: EngineInput) -> Self {
        let engine = routing_engine::Engine::new(routing_engine::EngineInput {
            stop_count: index_of(input.stop_count),
            connections: input.connections,
            transfers: input.transfers,
            minimum_transfer_s: input.minimum_transfer_s,
        });
        Self { engine }
    }

    /// The frontier of journeys leaving at or after `query.departure_s`, fewest
    /// changes first.
    #[must_use]
    pub fn route(&self, query: &Query) -> Vec<Journey> {
        let frontier = routing_engine::route(
            &self.engine.view(),
            &routing_engine::Query {
                origin: query.origin.query(),
                target: query.target,
                departure_s: query.departure_s,
            },
        );
        let mut journeys = Vec::with_capacity(frontier.len());
        for journey in frontier {
            journeys.push(Journey {
                arrival_s: journey.arrival_s,
                changes: count_u32(journey.changes),
                legs: legs_of(&journey.legs),
            });
        }
        journeys
    }

    /// The frontier of journeys arriving at or before `query.arrival_s`, fewest
    /// changes first.
    #[must_use]
    pub fn route_arriving_by(&self, query: &QueryArrivingBy) -> Vec<JourneyArrivingBy> {
        let frontier = routing_engine::route_arriving_by(
            &self.engine.view(),
            &routing_engine::QueryArrivingBy {
                origin: query.origin.query(),
                target: query.target,
                arrival_s: query.arrival_s,
            },
        );
        let mut journeys = Vec::with_capacity(frontier.len());
        for journey in frontier {
            journeys.push(JourneyArrivingBy {
                departure_s: journey.departure_s,
                arrival_s: journey.arrival_s,
                changes: count_u32(journey.changes),
                legs: legs_of(&journey.legs),
            });
        }
        journeys
    }
}

fn legs_of(legs: &[routing_engine::Leg]) -> Vec<Leg> {
    let mut crossed = Vec::with_capacity(legs.len());
    for &leg in legs {
        crossed.push(match leg {
            routing_engine::Leg::Ride {
                board_connection,
                alight_connection,
            } => Leg::Ride {
                board_connection: count_u32(board_connection),
                alight_connection: count_u32(alight_connection),
            },
            routing_engine::Leg::Walk {
                from_stop,
                to_stop,
                duration_s,
            } => Leg::Walk {
                from_stop: count_u32(from_stop),
                to_stop: count_u32(to_stop),
                duration_s,
            },
            routing_engine::Leg::WalkFromPosition {
                to_stop,
                duration_s,
            } => Leg::WalkFromPosition {
                to_stop: count_u32(to_stop),
                duration_s,
            },
        });
    }
    crossed
}

// A count or an index as a `u32`, which it must fit.
fn count_u32(count: usize) -> u32 {
    let Ok(number) = u32::try_from(count) else {
        gobusgo_core::assert::unreachable(&count, "binding: routing engine: a count fits a u32");
    };
    number
}

// A `u32` as an index, which every platform the binding builds for holds.
fn index_of(number: u32) -> usize {
    let Ok(index) = usize::try_from(number) else {
        gobusgo_core::assert::unreachable(&number, "binding: routing engine: a u32 fits a usize");
    };
    index
}

#[cfg(test)]
mod tests {
    // The binding passes the core's value through unchanged.
    #[test]
    fn core_version_is_the_core_version() {
        assert_eq!(super::core_version(), gobusgo_core::core_version());
    }

    // A record crosses field for field, so a plane comes back as the core's.
    #[test]
    fn tangent_plane_is_the_core_plane() {
        let reference = 47.6062;
        let plane = super::tangent_plane(reference);
        assert_eq!(plane, gobusgo_core::math::geodesy::tangent_plane(reference));
    }

    // An engine of one ride from stop 0 to stop 1, departing at 100 and
    // arriving at 200.
    fn one_ride_engine() -> super::RoutingEngine {
        super::RoutingEngine::new(super::EngineInput {
            stop_count: 2,
            connections: super::Connections {
                departure_s: vec![100],
                arrival_s: vec![200],
                departure_stop: vec![0],
                arrival_stop: vec![1],
                trip: vec![7],
                sequence: vec![0],
                boarding: vec![1],
                alighting: vec![1],
            },
            transfers: super::Transfers {
                from_stop: Vec::new(),
                to_stop: Vec::new(),
                duration_s: Vec::new(),
            },
            minimum_transfer_s: 0.0,
        })
    }

    // A journey crosses as the binding's records, its ride by its connections.
    #[test]
    fn route_crosses_the_ride() {
        let frontier = one_ride_engine().route(&super::Query {
            origin: super::Origin::Stop { stop: 0.0 },
            target: 1.0,
            departure_s: 0.0,
        });
        let ride = super::Leg::Ride {
            board_connection: 0,
            alight_connection: 0,
        };
        let journey = super::Journey {
            arrival_s: 200.0,
            changes: 0,
            legs: vec![ride],
        };
        assert_eq!(frontier, vec![journey]);
    }

    // A journey arriving by a time crosses with the time it leaves the origin.
    #[test]
    fn route_arriving_by_crosses_the_departure() {
        let frontier = one_ride_engine().route_arriving_by(&super::QueryArrivingBy {
            origin: super::Origin::Stop { stop: 0.0 },
            target: 1.0,
            arrival_s: 300.0,
        });
        let ride = super::Leg::Ride {
            board_connection: 0,
            alight_connection: 0,
        };
        let journey = super::JourneyArrivingBy {
            departure_s: 100.0,
            arrival_s: 200.0,
            changes: 0,
            legs: vec![ride],
        };
        assert_eq!(frontier, vec![journey]);
    }
}
