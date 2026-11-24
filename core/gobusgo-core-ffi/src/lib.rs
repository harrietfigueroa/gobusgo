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

use gobusgo_core::math::angles::{self, Turn};
use gobusgo_core::math::checks;
use gobusgo_core::math::geodesy::{self, Between, PlaneCoverage, Position, TangentPlane};
use gobusgo_core::math::interpolation::{self, Clamp, Lerp};
use gobusgo_core::routing_snapshot::{self, Connections, Transfers, Trip};
use gobusgo_core::trip_path;

// The names Swift and Kotlin know these types by, where the core's own name is
// another.
type SnapshotRefusal = routing_snapshot::RefusalReason;
type SnapshotPositions = routing_snapshot::Positions;
type PathPoint = trip_path::Point;
type PathStop = trip_path::Stop;

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
}
