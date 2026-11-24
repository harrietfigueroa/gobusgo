// Routes each query of the engine's shared fixture that leaves at a time with
// the core and compares the frontier with the one written by hand, each case
// and query labeled by its name. It then checks that each query the engine
// refuses fails with the message the JavaScript's refusal carries, the leaving
// half of the table of `tools/conformance/tests/routing_engine.test.mjs`
// restated, that a start stop named twice keeps its shorter walk in either
// order, that a label stores a time as the JavaScript's Int32Array does, with
// the JavaScript's answers restated, and that the core refuses the engine
// inputs and views it cannot scan.

use std::fmt::Debug;
use std::str::FromStr;

use gobusgo_core::routing_engine::{
    ConnectionColumns, Engine, EngineInput, EngineView, Journey, Leg, LegKind, LinkColumns, Origin,
    OriginKind, Query, ROUNDS_MAX, route,
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

const MINIMUM_TRANSFER_S: f64 = 120.0;
const LINK_S: u32 = 60;
const MEETING_FIRST_DEPARTURE_S: i32 = 28_800;
const MEETING_ARRIVAL_S: i32 = 29_400;
const MEETING_LAST_ARRIVAL_S: i32 = 30_000;
// 2^31, one past the largest `i32`.
const INT32_PAST_MAX: f64 = 2_147_483_648.0;

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

// Two trips meeting at stop 1, the second leaving the second the first
// arrives, with no walking link, the inputs of the JavaScript run whose
// answers the Int32 cases restate.
fn meeting_input(minimum_transfer_s: f64) -> EngineInput {
    EngineInput {
        stop_count: 3,
        connections: Connections {
            departure_s: vec![MEETING_FIRST_DEPARTURE_S, MEETING_ARRIVAL_S],
            arrival_s: vec![MEETING_ARRIVAL_S, MEETING_LAST_ARRIVAL_S],
            departure_stop: vec![0, 1],
            arrival_stop: vec![1, 2],
            trip: vec![0, 1],
            sequence: vec![0, 0],
            boarding: vec![1, 1],
            alighting: vec![1, 1],
        },
        transfers: Transfers {
            from_stop: Vec::new(),
            to_stop: Vec::new(),
            duration_s: Vec::new(),
        },
        minimum_transfer_s,
    }
}

// The meeting trips with a walking link out of each of the first two stops.
fn linked_input() -> EngineInput {
    EngineInput {
        transfers: Transfers {
            from_stop: vec![0, 1],
            to_stop: vec![1, 2],
            duration_s: vec![LINK_S, LINK_S],
        },
        ..meeting_input(MINIMUM_TRANSFER_S)
    }
}

fn from_stop_0(target: f64, departure_s: f64) -> HeldQuery {
    HeldQuery {
        origin: HeldOrigin::Stop(0.0),
        target,
        departure_s,
    }
}

// A label stores the arrival plus a half-second transfer as the JavaScript's
// Int32Array does, truncated to the arrival, so the second trip boards.
#[test]
fn a_fractional_minimum_transfer_is_stored_truncated() {
    let engine = Engine::new(meeting_input(0.5));
    let frontier = route(&engine.view(), &from_stop_0(2.0, 28_800.0).query());
    let expected = vec![Journey {
        arrival_s: f64::from(MEETING_LAST_ARRIVAL_S),
        changes: 1,
        legs: vec![
            Leg::Ride {
                board_connection: 0,
                alight_connection: 0,
            },
            Leg::Ride {
                board_connection: 1,
                alight_connection: 1,
            },
        ],
    }];
    assert_eq!(frontier, expected);
}

// A label stores a departure of 2^31 wrapped, as the JavaScript's Int32Array
// does, so a query whose origin is its target arrives at -2^31.
#[test]
fn a_departure_past_an_int32_is_stored_wrapped() {
    let engine = Engine::new(meeting_input(MINIMUM_TRANSFER_S));
    let frontier = route(&engine.view(), &from_stop_0(0.0, INT32_PAST_MAX).query());
    let expected = vec![Journey {
        arrival_s: f64::from(i32::MIN),
        changes: 0,
        legs: Vec::new(),
    }];
    assert_eq!(frontier, expected);
}

// Each input `Engine::new` refuses, by the rule it breaks, with the failure's
// message; these are the core's own refusals, which the JavaScript has none of.
#[test]
fn refused_engine_inputs() {
    let base = linked_input;
    let edited = |edit: fn(&mut EngineInput)| {
        let mut input = base();
        edit(&mut input);
        input
    };
    let refused = [
        (
            edited(|input| input.stop_count = usize::try_from(u64::from(u32::MAX) + 1).unwrap()),
            "routing engine: the stop count 4294967296 exceeds a u32",
        ),
        (
            edited(|input| input.connections.arrival_s.truncate(1)),
            "routing engine: the arrival_s column holds 1 values, not 2",
        ),
        (
            edited(|input| input.connections.departure_s.reverse()),
            "routing engine: the connections are not ordered by departure",
        ),
        (
            edited(|input| input.connections.departure_stop[0] = 3),
            "routing engine: 3 in the departure_stop column is not a stop of the snapshot",
        ),
        (
            edited(|input| input.connections.arrival_stop[1] = 3),
            "routing engine: 3 in the arrival_stop column is not a stop of the snapshot",
        ),
        (
            edited(|input| input.transfers.duration_s.truncate(1)),
            "routing engine: the duration_s column holds 1 values, not 2",
        ),
        (
            edited(|input| input.transfers.from_stop.reverse()),
            "routing engine: the walking links are not ordered by the stop they leave",
        ),
        (
            edited(|input| input.transfers.from_stop[1] = 3),
            "routing engine: 3 in the from_stop column is not a stop of the snapshot",
        ),
        (
            edited(|input| input.transfers.to_stop[1] = 3),
            "routing engine: 3 in the to_stop column is not a stop of the snapshot",
        ),
    ];
    for (input, message) in refused {
        let failure = failure_of(|| Engine::new(input));
        assert_eq!(failure.message(), message);
    }
}

// Each view `route` refuses, by the rule it breaks, with the failure's message.
#[test]
fn refused_views() {
    let engine = Engine::new(linked_input());
    let view = engine.view();
    let connections = view.connections;
    let links = view.links;
    let refused = [
        (
            EngineView {
                links: LinkColumns {
                    offsets: &[],
                    ..links
                },
                ..view
            },
            "routing engine: the view holds no link offsets",
        ),
        (
            EngineView {
                connections: ConnectionColumns {
                    trip_slot: &connections.trip_slot[..1],
                    ..connections
                },
                ..view
            },
            "routing engine: the trip_slot column holds 1 values, not 2",
        ),
        (
            EngineView {
                trip_count: 3,
                ..view
            },
            "routing engine: the trip count 3 exceeds the 2 connections",
        ),
        (
            EngineView {
                links: LinkColumns {
                    duration_s: &links.duration_s[..1],
                    ..links
                },
                ..view
            },
            "routing engine: the duration_s column holds 1 values, not 2",
        ),
        (
            EngineView {
                links: LinkColumns {
                    offsets: &[0, 2, 1, 2],
                    ..links
                },
                ..view
            },
            "routing engine: the link offsets decrease",
        ),
        (
            EngineView {
                links: LinkColumns {
                    offsets: &[0, 1, 1, 1],
                    ..links
                },
                ..view
            },
            "routing engine: the last link offset 1 is not the link count 2",
        ),
    ];
    let held = from_stop_0(2.0, f64::from(MEETING_FIRST_DEPARTURE_S));
    for (refused_view, message) in refused {
        let failure = failure_of(|| route(&refused_view, &held.query()));
        assert_eq!(failure.message(), message);
    }
}
