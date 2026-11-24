// Routes each query of the engine's shared fixture that leaves at a time with
// the core and compares the frontier with the one written by hand, each case
// and query found by its name. It then checks that each query the engine
// refuses fails with the message the JavaScript's refusal carries, the leaving
// half of the table of `tools/conformance/tests/routing_engine.test.mjs`
// restated, that a start stop named twice keeps its shorter walk in either
// order, and, over a chain of one-hop trips built here, that a journey takes
// at most six rides.

use std::fmt::Debug;
use std::str::FromStr;

use gobusgo_core::routing_engine::{
    Engine, EngineInput, Journey, Leg, LegKind, Origin, OriginKind, Query, ROUNDS_MAX, route,
};
use gobusgo_core::routing_snapshot::{Connections, Transfers};
use gobusgo_core::routing_walk::Start;

use crate::json::Value;
use crate::{failure_of, fixture};

const DIRECT_CASE_NAME: &str = "a direct ride stays aboard through the stops between";
const LEAVING_KIND: &str = "leaving";
const ROUND_COUNT_MAX: usize = 6;
const WALK_S_SHORTER: f64 = 60.0;
const WALK_S_LONGER: f64 = 120.0;
const NOT_A_STOP: &str = " is not a stop of the snapshot";

// A chain of one-hop trips, each leaving the stop the one before reaches, one
// more than a journey may ride.
const CHAIN_TRIP_COUNT: u32 = 7;
const CHAIN_HEADWAY_S: i32 = 600;
const CHAIN_RIDE_S: i32 = 300;

fn cases() -> Value {
    fixture(include_str!(
        "../../../../test/fixtures/routing/engine-v1/expected.json"
    ))
}

fn case_named<'cases>(cases: &'cases Value, name: &str) -> &'cases Value {
    let found = cases
        .get("cases")
        .items()
        .iter()
        .find(|case| case.get("name").text() == name);
    let Some(case) = found else {
        panic!("routing engine test: no case named {name}");
    };
    case
}

// A whole number the fixture writes, in the integer type a column holds.
fn whole<Number>(value: f64) -> Number
where
    Number: FromStr,
    Number::Err: Debug,
{
    format!("{value}").parse().unwrap()
}

fn column<Number>(values: &Value) -> Vec<Number>
where
    Number: FromStr,
    Number::Err: Debug,
{
    values.numbers().into_iter().map(whole).collect()
}

fn engine_of(case: &Value) -> Engine {
    let engine = case.get("engine");
    let connections = engine.get("connections");
    let transfers = engine.get("transfers");
    Engine::new(EngineInput {
        stop_count: whole(engine.get("stopCount").number()),
        connections: Connections {
            departure_s: column(connections.get("departureS")),
            arrival_s: column(connections.get("arrivalS")),
            departure_stop: column(connections.get("departureStop")),
            arrival_stop: column(connections.get("arrivalStop")),
            trip: column(connections.get("trip")),
            sequence: column(connections.get("sequence")),
            boarding: column(connections.get("boarding")),
            alighting: column(connections.get("alighting")),
        },
        transfers: Transfers {
            from_stop: column(transfers.get("fromStop")),
            to_stop: column(transfers.get("toStop")),
            duration_s: column(transfers.get("durationS")),
        },
        minimum_transfer_s: engine.get("minimumTransferS").number(),
    })
}

// A query's origin as the test holds it, which a `Query` borrows.
enum HeldOrigin {
    Stop(f64),
    Starts(Vec<Start>),
    Unknown(String),
}

struct HeldQuery {
    origin: HeldOrigin,
    target: f64,
    departure_s: f64,
}

impl HeldQuery {
    fn query(&self) -> Query<'_> {
        let origin = match &self.origin {
            HeldOrigin::Stop(stop) => Origin::Stop { stop: *stop },
            HeldOrigin::Starts(starts) => Origin::Starts { starts },
            HeldOrigin::Unknown(kind) => Origin::Unknown { kind },
        };
        Query {
            origin,
            target: self.target,
            departure_s: self.departure_s,
        }
    }
}

fn starts_of(starts: &Value) -> Vec<Start> {
    let start = |value: &Value| Start {
        stop: value.get("stop").number(),
        walk_s: value.get("walkS").number(),
    };
    starts.items().iter().map(start).collect()
}

fn query_of(query: &Value) -> HeldQuery {
    let origin = query.get("origin");
    let held = match origin.get("kind").text() {
        "stop" => HeldOrigin::Stop(origin.get("stop").number()),
        "starts" => HeldOrigin::Starts(starts_of(origin.get("starts"))),
        other => HeldOrigin::Unknown(other.to_owned()),
    };
    HeldQuery {
        origin: held,
        target: query.get("target").number(),
        departure_s: query.get("departureS").number(),
    }
}

fn leg_of(leg: &Value) -> Leg {
    match leg.get("kind").text() {
        "ride" => Leg::Ride {
            board_connection: whole(leg.get("boardConnection").number()),
            alight_connection: whole(leg.get("alightConnection").number()),
        },
        "walk" => Leg::Walk {
            from_stop: whole(leg.get("fromStop").number()),
            to_stop: whole(leg.get("toStop").number()),
            duration_s: leg.get("durationS").number(),
        },
        "walkFromPosition" => Leg::WalkFromPosition {
            to_stop: whole(leg.get("toStop").number()),
            duration_s: leg.get("durationS").number(),
        },
        other => panic!("routing engine test: a leg of unknown kind {other}"),
    }
}

fn frontier_of(expected: &Value) -> Vec<Journey> {
    let journey = |value: &Value| Journey {
        arrival_s: value.get("arrivalS").number(),
        changes: whole(value.get("changes").number()),
        legs: value.get("legs").items().iter().map(leg_of).collect(),
    };
    expected.items().iter().map(journey).collect()
}

// The index of the stop `id` names in a case.
fn stop_named(case: &Value, id: &str) -> f64 {
    let found = case
        .get("stopIds")
        .items()
        .iter()
        .position(|stop_id| stop_id.text() == id);
    let Some(index) = found else {
        panic!("routing engine test: no stop {id}");
    };
    format!("{index}").parse().unwrap()
}

// The index of the one connection whose `column` holds `stop`.
fn only_connection(column: &Value, stop: f64) -> usize {
    let indices: Vec<usize> = column
        .numbers()
        .into_iter()
        .enumerate()
        .filter(|(_, value)| value.total_cmp(&stop).is_eq())
        .map(|(index, _)| index)
        .collect();
    assert_eq!(indices.len(), 1, "connections holding the stop {stop}");
    indices[0]
}

#[test]
fn the_legs_name_a_ride_a_walk_and_a_walk_from_the_position() {
    let names = LegKind::ALL.map(LegKind::name);
    assert_eq!(names, ["ride", "walk", "walkFromPosition"]);
}

#[test]
fn the_origins_name_a_stop_and_start_stops() {
    let names = OriginKind::ALL.map(OriginKind::name);
    assert_eq!(names, ["stop", "starts"]);
}

#[test]
fn a_journey_takes_at_most_six_rides() {
    assert_eq!(ROUNDS_MAX, ROUND_COUNT_MAX);
}

#[test]
fn leaving_queries() {
    let cases = cases();
    let mut query_count = 0_usize;
    for case in cases.get("cases").items() {
        let engine = engine_of(case);
        for query in case.get("queries").items() {
            if query.get("kind").text() != LEAVING_KIND {
                continue;
            }
            let held = query_of(query.get("query"));
            let frontier = route(&engine.view(), &held.query());
            assert_eq!(
                frontier,
                frontier_of(query.get("expected")),
                "{}: {}",
                case.get("name").text(),
                query.get("name").text()
            );
            query_count += 1;
        }
    }
    assert!(query_count > 0, "the fixture holds no leaving query");
}

#[test]
fn refused_queries() {
    let cases = cases();
    let case = case_named(&cases, DIRECT_CASE_NAME);
    let engine = engine_of(case);
    let stop_count = case.get("engine").get("stopCount").number();
    let stop_a = stop_named(case, "A");
    let stop_c = stop_named(case, "C");
    let at_stop_a = || HeldOrigin::Stop(stop_a);
    let starts = |stop: f64, walk_s: f64| HeldOrigin::Starts(vec![Start { stop, walk_s }]);
    let refused = [
        (
            at_stop_a(),
            stop_count,
            0.0,
            format!("routing engine: the target {stop_count}{NOT_A_STOP}"),
        ),
        (
            at_stop_a(),
            -1.0,
            0.0,
            format!("routing engine: the target -1{NOT_A_STOP}"),
        ),
        (
            at_stop_a(),
            0.5,
            0.0,
            format!("routing engine: the target 0.5{NOT_A_STOP}"),
        ),
        (
            at_stop_a(),
            stop_c,
            0.5,
            "routing engine: the departure is not whole seconds: 0.5".to_owned(),
        ),
        (
            HeldOrigin::Stop(stop_count),
            stop_c,
            0.0,
            format!("routing engine: the origin stop {stop_count}{NOT_A_STOP}"),
        ),
        (
            HeldOrigin::Starts(Vec::new()),
            stop_c,
            0.0,
            "routing engine: a query from start stops names none".to_owned(),
        ),
        (
            starts(stop_count, 0.0),
            stop_c,
            0.0,
            format!("routing engine: the start stop {stop_count}{NOT_A_STOP}"),
        ),
        (
            starts(stop_a, 0.5),
            stop_c,
            0.0,
            "routing engine: a start stop's walk is not whole seconds: 0.5".to_owned(),
        ),
        (
            starts(stop_a, -1.0),
            stop_c,
            0.0,
            "routing engine: a start stop's walk is negative: -1".to_owned(),
        ),
        (
            HeldOrigin::Unknown("position".to_owned()),
            stop_c,
            0.0,
            "routing engine: an origin of unknown kind: position".to_owned(),
        ),
    ];
    for (origin, target, departure_s, message) in refused {
        let held = HeldQuery {
            origin,
            target,
            departure_s,
        };
        let failure = failure_of(|| route(&engine.view(), &held.query()));
        assert_eq!(failure.message(), message);
    }
}

// A start stop named twice, in both orders, so only keeping the shorter walk
// passes whichever comes first.
#[test]
fn a_start_stop_named_twice_keeps_its_shorter_walk() {
    let cases = cases();
    let case = case_named(&cases, DIRECT_CASE_NAME);
    let engine = engine_of(case);
    let connections = case.get("engine").get("connections");
    let stop_a = stop_named(case, "A");
    let stop_c = stop_named(case, "C");
    let board_at_a = only_connection(connections.get("departureStop"), stop_a);
    let alight_at_c = only_connection(connections.get("arrivalStop"), stop_c);
    let board_s = connections.get("departureS").items()[board_at_a].number();
    let arrival_s = connections.get("arrivalS").items()[alight_at_c].number();
    let shorter = Start {
        stop: stop_a,
        walk_s: WALK_S_SHORTER,
    };
    let longer = Start {
        stop: stop_a,
        walk_s: WALK_S_LONGER,
    };
    let expected = vec![Journey {
        arrival_s,
        changes: 0,
        legs: vec![
            Leg::WalkFromPosition {
                to_stop: whole(stop_a),
                duration_s: WALK_S_SHORTER,
            },
            Leg::Ride {
                board_connection: board_at_a,
                alight_connection: alight_at_c,
            },
        ],
    }];
    for starts in [[longer, shorter], [shorter, longer]] {
        let held = HeldQuery {
            origin: HeldOrigin::Starts(starts.to_vec()),
            target: stop_c,
            departure_s: board_s - WALK_S_LONGER,
        };
        let frontier = route(&engine.view(), &held.query());
        assert_eq!(frontier, expected, "starts: {starts:?}");
    }
}

// Trip `t` rides from stop `t` to stop `t + 1`, leaving after the one before
// arrives, so reaching stop `n` from stop 0 takes `n` rides.
fn chain_engine() -> Engine {
    let trips: Vec<u32> = (0..CHAIN_TRIP_COUNT).collect();
    let departure_s: Vec<i32> = trips
        .iter()
        .map(|&trip| {
            i32::try_from(trip)
                .unwrap()
                .checked_mul(CHAIN_HEADWAY_S)
                .unwrap()
        })
        .collect();
    let trip_count = trips.len();
    Engine::new(EngineInput {
        stop_count: trip_count.checked_add(1).unwrap(),
        connections: Connections {
            arrival_s: departure_s
                .iter()
                .map(|&s| s.checked_add(CHAIN_RIDE_S).unwrap())
                .collect(),
            departure_s,
            departure_stop: trips.clone(),
            arrival_stop: trips
                .iter()
                .map(|&trip| trip.checked_add(1).unwrap())
                .collect(),
            trip: trips,
            sequence: vec![0; trip_count],
            boarding: vec![1; trip_count],
            alighting: vec![1; trip_count],
        },
        transfers: Transfers {
            from_stop: Vec::new(),
            to_stop: Vec::new(),
            duration_s: Vec::new(),
        },
        minimum_transfer_s: 0.0,
    })
}

fn chain_query(target: usize) -> HeldQuery {
    HeldQuery {
        origin: HeldOrigin::Stop(0.0),
        target: format!("{target}").parse().unwrap(),
        departure_s: 0.0,
    }
}

#[test]
fn six_rides_reach_the_sixth_stop_of_a_chain() {
    let engine = chain_engine();
    let frontier = route(&engine.view(), &chain_query(ROUND_COUNT_MAX).query());
    let rides: Vec<Leg> = (0..ROUND_COUNT_MAX)
        .map(|connection| Leg::Ride {
            board_connection: connection,
            alight_connection: connection,
        })
        .collect();
    let last_trip = i32::try_from(ROUND_COUNT_MAX - 1).unwrap();
    let arrival_s = f64::from(last_trip * CHAIN_HEADWAY_S + CHAIN_RIDE_S);
    let expected = vec![Journey {
        arrival_s,
        changes: ROUND_COUNT_MAX - 1,
        legs: rides,
    }];
    assert_eq!(frontier, expected);
}

#[test]
fn no_journey_takes_a_seventh_ride() {
    let engine = chain_engine();
    let frontier = route(&engine.view(), &chain_query(ROUND_COUNT_MAX + 1).query());
    assert_eq!(frontier, Vec::new());
}
