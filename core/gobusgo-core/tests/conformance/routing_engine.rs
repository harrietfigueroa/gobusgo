// Routes each query of the engine's shared fixture with the core, leaving at a
// time and arriving by one, and compares the frontier with the one written by
// hand, each case and query labeled by its name. It then checks that each
// query the engine refuses fails with the message the JavaScript's refusal
// carries, the table of `tools/conformance/tests/routing_engine.test.mjs`
// restated, that a query leaving at a time takes a start stop named twice and
// keeps its shorter walk in either order, that a label stores a time and a leg
// reads its duration back as the JavaScript's Int32Array holds them, that the
// incoming links are the JavaScript's, with the JavaScript's answers restated,
// and that the core refuses the engine inputs and views it cannot scan.

use std::fmt::Debug;
use std::str::FromStr;

use gobusgo_core::routing_engine::{
    ConnectionColumns, Engine, EngineInput, EngineView, IncomingLinkColumns, Journey,
    JourneyArrivingBy, Leg, LegKind, LinkColumns, Origin, OriginKind, Query, QueryArrivingBy,
    ROUNDS_MAX, route, route_arriving_by,
};
use gobusgo_core::routing_snapshot::{Connections, Transfers};
use gobusgo_core::routing_walk::Start;

use crate::json::Value;
use crate::{failure_of, fixture};

const DIRECT_CASE_NAME: &str = "a direct ride stays aboard through the stops between";
const LEAVING_KIND: &str = "leaving";
const ARRIVING_BY_KIND: &str = "arrivingBy";
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
const LINK_S_PAST_INT32: u32 = 2_147_483_648;
// One ride from stop 0 to stop 1 well before the day starts, then a walking
// link of 2^31 + 5 seconds, which wraps to -2147483643 on its leg.
const EARLY_RIDE_DEPARTURE_S: i32 = -100_000;
const EARLY_RIDE_ARRIVAL_S: i32 = -50_000;
const EARLY_QUERY_DEPARTURE_S: f64 = -200_000.0;
const LINK_S_PAST_INT32_BY_5: u32 = 2_147_483_653;
const ARRIVAL_S_AFTER_LONG_LINK: f64 = 2_147_433_653.0;
const LEG_S_AFTER_LONG_LINK: f64 = -2_147_483_643.0;
// A departure two seconds before a walk of 2^31 seconds ends at the largest
// time a label holds below the unreached one.
const DEPARTURE_BEFORE_WRAP_S: f64 = -2.0;
const ARRIVAL_BEFORE_WRAP_S: f64 = 2_147_483_646.0;
// One ride from stop 0 to stop 1 that arrives at -2^31, at or before the time
// of a stop no round reaches, so it alights there.
const RIDE_ARRIVAL_S_AT_INT32_MIN: i32 = i32::MIN;
const ARRIVAL_S_AFTER_EARLY_RIDE: f64 = 100.0;
// A start walk of 2^32 - 1 seconds, which an Int32Array holds as -1.
const WALK_S_STORED_AS_MINUS_1: f64 = 4_294_967_295.0;
// The meeting trips moved before the day starts, so a half-second transfer
// truncated toward zero lets the first trip alight in time for the second.
const NEGATIVE_FIRST_DEPARTURE_S: i32 = -30_000;
const NEGATIVE_MEETING_S: i32 = -29_400;
const NEGATIVE_LAST_ARRIVAL_S: i32 = -28_800;

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

// A query's origin as the test holds it, which a query borrows.
enum HeldOrigin {
    Stop(f64),
    Starts(Vec<Start>),
    Unknown(String),
}

struct HeldQuery {
    origin: HeldOrigin,
    target: f64,
    time_s: f64,
}

impl HeldQuery {
    fn origin(&self) -> Origin<'_> {
        match &self.origin {
            HeldOrigin::Stop(stop) => Origin::Stop { stop: *stop },
            HeldOrigin::Starts(starts) => Origin::Starts { starts },
            HeldOrigin::Unknown(kind) => Origin::Unknown { kind },
        }
    }

    // The query leaving at the held time.
    fn leaving(&self) -> Query<'_> {
        Query {
            origin: self.origin(),
            target: self.target,
            departure_s: self.time_s,
        }
    }

    // The query arriving by the held time.
    fn arriving_by(&self) -> QueryArrivingBy<'_> {
        QueryArrivingBy {
            origin: self.origin(),
            target: self.target,
            arrival_s: self.time_s,
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

// A query of the fixture, its time read from the member `time_name`.
fn query_of(query: &Value, time_name: &str) -> HeldQuery {
    let origin = query.get("origin");
    let held = match origin.get("kind").text() {
        "stop" => HeldOrigin::Stop(origin.get("stop").number()),
        "starts" => HeldOrigin::Starts(starts_of(origin.get("starts"))),
        other => HeldOrigin::Unknown(other.to_owned()),
    };
    HeldQuery {
        origin: held,
        target: query.get("target").number(),
        time_s: query.get(time_name).number(),
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

fn frontier_arriving_by_of(expected: &Value) -> Vec<JourneyArrivingBy> {
    let journey = |value: &Value| JourneyArrivingBy {
        departure_s: value.get("departureS").number(),
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
            let held = query_of(query.get("query"), "departureS");
            let frontier = route(&engine.view(), &held.leaving());
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
fn arriving_by_queries() {
    let cases = cases();
    let mut query_count = 0_usize;
    for case in cases.get("cases").items() {
        let engine = engine_of(case);
        for query in case.get("queries").items() {
            if query.get("kind").text() != ARRIVING_BY_KIND {
                continue;
            }
            let held = query_of(query.get("query"), "arrivalS");
            let frontier = route_arriving_by(&engine.view(), &held.arriving_by());
            assert_eq!(
                frontier,
                frontier_arriving_by_of(query.get("expected")),
                "{}: {}",
                case.get("name").text(),
                query.get("name").text()
            );
            query_count += 1;
        }
    }
    assert!(
        query_count > 0,
        "the fixture holds no query arriving by a time"
    );
}

#[test]
fn refused_leaving_queries() {
    let cases = cases();
    let case = case_named(&cases, DIRECT_CASE_NAME);
    let engine = engine_of(case);
    let mut refused = refused_by_both(case);
    refused.push((
        HeldOrigin::Stop(stop_named(case, "A")),
        stop_named(case, "C"),
        0.5,
        "routing engine: the departure is not whole seconds: 0.5".to_owned(),
    ));
    for (origin, target, time_s, message) in refused {
        let held = HeldQuery {
            origin,
            target,
            time_s,
        };
        let failure = failure_of(|| route(&engine.view(), &held.leaving()));
        assert_eq!(failure.message(), message);
    }
}

#[test]
fn refused_queries_arriving_by() {
    let cases = cases();
    let case = case_named(&cases, DIRECT_CASE_NAME);
    let engine = engine_of(case);
    let stop_a = stop_named(case, "A");
    let stop_c = stop_named(case, "C");
    let mut refused = refused_by_both(case);
    refused.push((
        HeldOrigin::Stop(stop_a),
        stop_c,
        0.5,
        "routing engine: the arrival is not whole seconds: 0.5".to_owned(),
    ));
    let longer = Start {
        stop: stop_a,
        walk_s: WALK_S_LONGER,
    };
    let shorter = Start {
        stop: stop_a,
        walk_s: WALK_S_SHORTER,
    };
    refused.push((
        HeldOrigin::Starts(vec![longer, shorter]),
        stop_c,
        0.0,
        format!("routing engine: the start stop {stop_a} is named twice"),
    ));
    for (origin, target, time_s, message) in refused {
        let held = HeldQuery {
            origin,
            target,
            time_s,
        };
        let failure = failure_of(|| route_arriving_by(&engine.view(), &held.arriving_by()));
        assert_eq!(failure.message(), message);
    }
}

// A query the engine refuses, at time 0 unless a fraction is the rule it
// breaks, and the failure's message.
type Refused = (HeldOrigin, f64, f64, String);

// The queries both `route` and `route_arriving_by` refuse, at time 0, by the
// rule each breaks, with the failure's message.
fn refused_by_both(case: &Value) -> Vec<Refused> {
    let stop_count = case.get("engine").get("stopCount").number();
    let stop_a = stop_named(case, "A");
    let stop_c = stop_named(case, "C");
    let at_stop_a = || HeldOrigin::Stop(stop_a);
    let starts = |stop: f64, walk_s: f64| HeldOrigin::Starts(vec![Start { stop, walk_s }]);
    vec![
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
    ]
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
            time_s: board_s - WALK_S_LONGER,
        };
        let frontier = route(&engine.view(), &held.leaving());
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

fn from_stop_0(target: f64, time_s: f64) -> HeldQuery {
    HeldQuery {
        origin: HeldOrigin::Stop(0.0),
        target,
        time_s,
    }
}

// A label stores the arrival plus a half-second transfer as the JavaScript's
// Int32Array does, truncated to the arrival, so the second trip boards.
#[test]
fn a_fractional_minimum_transfer_is_stored_truncated() {
    let engine = Engine::new(meeting_input(0.5));
    let frontier = route(&engine.view(), &from_stop_0(2.0, 28_800.0).leaving());
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
    let frontier = route(&engine.view(), &from_stop_0(0.0, INT32_PAST_MAX).leaving());
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
                trip_count: 3,
                ..view
            },
            "routing engine: the trip count 3 exceeds the 2 connections",
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
        let failure = failure_of(|| route(&refused_view, &held.leaving()));
        assert_eq!(failure.message(), message);
    }
}

// Each view `route_arriving_by` refuses by its incoming links, by the rule it
// breaks, with the failure's message.
#[test]
fn refused_incoming_links() {
    let engine = Engine::new(linked_input());
    let view = engine.view();
    let incoming = view.incoming;
    let refused = [
        (
            EngineView {
                incoming: IncomingLinkColumns {
                    offsets: &[0, 1, 2],
                    ..incoming
                },
                ..view
            },
            "routing engine: the view holds 3 incoming link offsets, not 4",
        ),
        (
            EngineView {
                incoming: IncomingLinkColumns {
                    offsets: &[0, 2, 1, 2],
                    ..incoming
                },
                ..view
            },
            "routing engine: the incoming link offsets decrease",
        ),
        (
            EngineView {
                incoming: IncomingLinkColumns {
                    offsets: &[0, 0, 1, 1],
                    ..incoming
                },
                ..view
            },
            "routing engine: the last incoming link offset 1 is not the incoming link count 2",
        ),
        (
            EngineView {
                incoming: IncomingLinkColumns {
                    duration_s: &incoming.duration_s[..1],
                    ..incoming
                },
                ..view
            },
            "routing engine: the incoming_duration_s column holds 1 values, not 2",
        ),
    ];
    let held = from_stop_0(2.0, f64::from(MEETING_LAST_ARRIVAL_S));
    for (refused_view, message) in refused {
        let failure = failure_of(|| route_arriving_by(&refused_view, &held.arriving_by()));
        assert_eq!(failure.message(), message);
    }
}

// The links into each stop, ordered by the stop they reach and then as the
// snapshot orders them; the columns are the JavaScript's `incomingLinks` over
// the same links.
#[test]
fn the_incoming_links_are_ordered_by_the_stop_they_reach() {
    let engine = Engine::new(EngineInput {
        stop_count: 4,
        transfers: Transfers {
            from_stop: vec![0, 0, 1, 2, 3],
            to_stop: vec![2, 1, 2, 0, 2],
            duration_s: vec![10, 20, 30, 40, 50],
        },
        ..meeting_input(MINIMUM_TRANSFER_S)
    });
    let incoming = engine.view().incoming;
    let expected = IncomingLinkColumns {
        offsets: &[0, 1, 2, 5, 5],
        from_stop: &[2, 0, 0, 1, 3],
        duration_s: &[40, 20, 10, 30, 50],
    };
    assert_eq!(incoming, expected);
}

// A walk from the position of 2^31 seconds reads back wrapped, as the
// JavaScript's Int32Array column of durations holds it; the answer is the
// JavaScript's over the same inputs.
#[test]
fn a_start_walk_past_an_int32_reads_back_wrapped() {
    let engine = Engine::new(meeting_input(MINIMUM_TRANSFER_S));
    let held = HeldQuery {
        origin: HeldOrigin::Starts(vec![Start {
            stop: 1.0,
            walk_s: INT32_PAST_MAX,
        }]),
        target: 1.0,
        time_s: DEPARTURE_BEFORE_WRAP_S,
    };
    let frontier = route(&engine.view(), &held.leaving());
    let expected = vec![Journey {
        arrival_s: ARRIVAL_BEFORE_WRAP_S,
        changes: 0,
        legs: vec![Leg::WalkFromPosition {
            to_stop: 1,
            duration_s: f64::from(i32::MIN),
        }],
    }];
    assert_eq!(frontier, expected);
}

// A walking link of 2^31 seconds reads back wrapped on its leg, while the time
// it reaches counts the whole link; the answer is the JavaScript's over the
// same inputs.
#[test]
fn a_link_past_an_int32_reads_back_wrapped() {
    let engine = Engine::new(EngineInput {
        transfers: Transfers {
            from_stop: vec![0],
            to_stop: vec![1],
            duration_s: vec![LINK_S_PAST_INT32],
        },
        ..meeting_input(MINIMUM_TRANSFER_S)
    });
    let frontier = route(
        &engine.view(),
        &from_stop_0(1.0, DEPARTURE_BEFORE_WRAP_S).leaving(),
    );
    let expected = vec![
        Journey {
            arrival_s: ARRIVAL_BEFORE_WRAP_S,
            changes: 0,
            legs: vec![Leg::Walk {
                from_stop: 0,
                to_stop: 1,
                duration_s: f64::from(i32::MIN),
            }],
        },
        Journey {
            arrival_s: f64::from(MEETING_ARRIVAL_S),
            changes: 0,
            legs: vec![Leg::Ride {
                board_connection: 0,
                alight_connection: 0,
            }],
        },
    ];
    assert_eq!(frontier, expected);
}

// An edit that shortens one column of an engine's input, and that column's name.
type Shortening = (fn(&mut EngineInput), &'static str);

// Each column `Engine::new` reads, shortened in turn, refused by its name.
#[test]
fn refused_engine_input_lengths() {
    let shortened: [Shortening; 9] = [
        (|input| input.connections.arrival_s.truncate(1), "arrival_s"),
        (
            |input| input.connections.departure_stop.truncate(1),
            "departure_stop",
        ),
        (
            |input| input.connections.arrival_stop.truncate(1),
            "arrival_stop",
        ),
        (|input| input.connections.trip.truncate(1), "trip"),
        (|input| input.connections.sequence.truncate(1), "sequence"),
        (|input| input.connections.boarding.truncate(1), "boarding"),
        (|input| input.connections.alighting.truncate(1), "alighting"),
        (|input| input.transfers.to_stop.truncate(1), "to_stop"),
        (|input| input.transfers.duration_s.truncate(1), "duration_s"),
    ];
    for (shorten, name) in shortened {
        let mut input = linked_input();
        shorten(&mut input);
        let failure = failure_of(|| Engine::new(input));
        assert_eq!(
            failure.message(),
            format!("routing engine: the {name} column holds 1 values, not 2")
        );
    }
}

// Each column of a view `route` reads, shortened in turn, refused by its name.
#[test]
fn refused_view_lengths() {
    let engine = Engine::new(linked_input());
    let view = engine.view();
    let columns = view.connections;
    let shortened = [
        (
            ConnectionColumns {
                arrival_s: &columns.arrival_s[..1],
                ..columns
            },
            "arrival_s",
        ),
        (
            ConnectionColumns {
                departure_stop: &columns.departure_stop[..1],
                ..columns
            },
            "departure_stop",
        ),
        (
            ConnectionColumns {
                arrival_stop: &columns.arrival_stop[..1],
                ..columns
            },
            "arrival_stop",
        ),
        (
            ConnectionColumns {
                trip_slot: &columns.trip_slot[..1],
                ..columns
            },
            "trip_slot",
        ),
        (
            ConnectionColumns {
                boarding: &columns.boarding[..1],
                ..columns
            },
            "boarding",
        ),
        (
            ConnectionColumns {
                alighting: &columns.alighting[..1],
                ..columns
            },
            "alighting",
        ),
    ];
    let mut refused: Vec<(EngineView<'_>, &str)> = Vec::new();
    for (connections, name) in shortened {
        refused.push((
            EngineView {
                connections,
                ..view
            },
            name,
        ));
    }
    let short_links = LinkColumns {
        duration_s: &view.links.duration_s[..1],
        ..view.links
    };
    refused.push((
        EngineView {
            links: short_links,
            ..view
        },
        "duration_s",
    ));
    let held = from_stop_0(2.0, f64::from(MEETING_FIRST_DEPARTURE_S));
    for (refused_view, name) in refused {
        let failure = failure_of(|| route(&refused_view, &held.leaving()));
        assert_eq!(
            failure.message(),
            format!("routing engine: the {name} column holds 1 values, not 2")
        );
    }
}

// A walk of 2^31 + 5 seconds after a ride reads back wrapped on its leg, while
// the time it reaches counts the whole link; the answer is the JavaScript's
// over the same inputs.
#[test]
fn a_walk_after_a_ride_past_an_int32_reads_back_wrapped() {
    let engine = Engine::new(EngineInput {
        stop_count: 3,
        connections: Connections {
            departure_s: vec![EARLY_RIDE_DEPARTURE_S],
            arrival_s: vec![EARLY_RIDE_ARRIVAL_S],
            departure_stop: vec![0],
            arrival_stop: vec![1],
            trip: vec![0],
            sequence: vec![0],
            boarding: vec![1],
            alighting: vec![1],
        },
        transfers: Transfers {
            from_stop: vec![1],
            to_stop: vec![2],
            duration_s: vec![LINK_S_PAST_INT32_BY_5],
        },
        minimum_transfer_s: MINIMUM_TRANSFER_S,
    });
    let frontier = route(
        &engine.view(),
        &from_stop_0(2.0, EARLY_QUERY_DEPARTURE_S).leaving(),
    );
    let expected = vec![Journey {
        arrival_s: ARRIVAL_S_AFTER_LONG_LINK,
        changes: 0,
        legs: vec![
            Leg::Ride {
                board_connection: 0,
                alight_connection: 0,
            },
            Leg::Walk {
                from_stop: 1,
                to_stop: 2,
                duration_s: LEG_S_AFTER_LONG_LINK,
            },
        ],
    }];
    assert_eq!(frontier, expected);
}

// A ride arriving at -2^31 alights at a stop no round reaches, whose label
// holds -2^31 + 1, so its journey ends there rather than at the target; the
// JavaScript refuses it with the same message over the same inputs.
#[test]
fn a_journey_arriving_by_a_time_ends_at_its_target() {
    let engine = Engine::new(EngineInput {
        stop_count: 3,
        connections: Connections {
            departure_s: vec![0],
            arrival_s: vec![RIDE_ARRIVAL_S_AT_INT32_MIN],
            departure_stop: vec![0],
            arrival_stop: vec![1],
            trip: vec![0],
            sequence: vec![0],
            boarding: vec![1],
            alighting: vec![1],
        },
        ..meeting_input(MINIMUM_TRANSFER_S)
    });
    let held = from_stop_0(2.0, ARRIVAL_S_AFTER_EARLY_RIDE);
    let failure = failure_of(|| route_arriving_by(&engine.view(), &held.arriving_by()));
    assert_eq!(
        failure.message(),
        "routing engine: a journey arriving by a time ends at 1, not the target 2"
    );
}

// A start walk of 2^32 - 1 seconds is held as -1, the mark of a stop that is
// no start, as the JavaScript's Int32Array holds it, so the stop named again
// is taken with its second walk; the answer is the JavaScript's over the same
// inputs.
#[test]
fn a_start_walk_held_as_minus_1_lets_its_stop_be_named_again() {
    let engine = Engine::new(meeting_input(MINIMUM_TRANSFER_S));
    let held = HeldQuery {
        origin: HeldOrigin::Starts(vec![
            Start {
                stop: 0.0,
                walk_s: WALK_S_STORED_AS_MINUS_1,
            },
            Start {
                stop: 0.0,
                walk_s: WALK_S_SHORTER,
            },
        ]),
        target: 1.0,
        time_s: f64::from(MEETING_ARRIVAL_S),
    };
    let frontier = route_arriving_by(&engine.view(), &held.arriving_by());
    let expected = vec![JourneyArrivingBy {
        departure_s: f64::from(MEETING_FIRST_DEPARTURE_S) - WALK_S_SHORTER,
        arrival_s: f64::from(MEETING_ARRIVAL_S),
        changes: 0,
        legs: vec![
            Leg::WalkFromPosition {
                to_stop: 0,
                duration_s: WALK_S_SHORTER,
            },
            Leg::Ride {
                board_connection: 0,
                alight_connection: 0,
            },
        ],
    }];
    assert_eq!(frontier, expected);
}

// A label stores a boarding less a half-second transfer as the JavaScript's
// Int32Array does, truncated toward zero, which before the day starts is the
// boarding itself, so the first trip alights in time for the second; the
// answer is the JavaScript's over the same inputs.
#[test]
fn a_fractional_minimum_transfer_before_the_day_is_stored_truncated() {
    let engine = Engine::new(EngineInput {
        connections: Connections {
            departure_s: vec![NEGATIVE_FIRST_DEPARTURE_S, NEGATIVE_MEETING_S],
            arrival_s: vec![NEGATIVE_MEETING_S, NEGATIVE_LAST_ARRIVAL_S],
            ..meeting_input(0.5).connections
        },
        ..meeting_input(0.5)
    });
    let held = from_stop_0(2.0, f64::from(NEGATIVE_LAST_ARRIVAL_S));
    let frontier = route_arriving_by(&engine.view(), &held.arriving_by());
    let expected = vec![JourneyArrivingBy {
        departure_s: f64::from(NEGATIVE_FIRST_DEPARTURE_S),
        arrival_s: f64::from(NEGATIVE_LAST_ARRIVAL_S),
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

// A start walk of 2^31 seconds reads back whole on a journey arriving by a
// time, which leaves 2^31 seconds before its boarding; the answer is the
// JavaScript's over the same inputs.
#[test]
fn a_start_walk_past_an_int32_reads_back_whole_when_arriving_by() {
    let engine = Engine::new(meeting_input(MINIMUM_TRANSFER_S));
    let held = HeldQuery {
        origin: HeldOrigin::Starts(vec![Start {
            stop: 0.0,
            walk_s: INT32_PAST_MAX,
        }]),
        target: 1.0,
        time_s: f64::from(MEETING_ARRIVAL_S),
    };
    let frontier = route_arriving_by(&engine.view(), &held.arriving_by());
    let expected = vec![JourneyArrivingBy {
        departure_s: f64::from(MEETING_FIRST_DEPARTURE_S) - INT32_PAST_MAX,
        arrival_s: f64::from(MEETING_ARRIVAL_S),
        changes: 0,
        legs: vec![
            Leg::WalkFromPosition {
                to_stop: 0,
                duration_s: INT32_PAST_MAX,
            },
            Leg::Ride {
                board_connection: 0,
                alight_connection: 0,
            },
        ],
    }];
    assert_eq!(frontier, expected);
}
