// Runs each case of the walk's shared fixture against the core and compares
// the answer with the one written by hand: the basis a manifest entry's rules
// give and whether it plans a walk on the streets, the street length bound,
// the start stops and the street search's candidates near a position, and the
// start stops a reach's street meters give. It then checks that each input the
// walk refuses fails with the message the JavaScript's refusal carries, the
// table of `tools/conformance/tests/routing_walk.test.mjs` restated.

use gobusgo_core::math::geodesy::Position;
use gobusgo_core::routing_snapshot::Positions;
use gobusgo_core::routing_walk::{
    Candidate, Near, ReachedStop, Start, WALK_CANDIDATE_COUNT_MAX, WalkBasis, WalkRules,
    is_street_walk, starts_from_streets, starts_near, street_meters_max_of, walk_basis_of,
    walk_candidates_near,
};

use crate::json::Value;
use crate::{failure_of, fixture};

const NEAR_CASE_NAME: &str = "stops within the radius and past it, and one with no known position";
const BOUND_CASE_NAME: &str = "260 stops within the radius, under a link bound of three";
const STREETS_CASE_NAME: &str = "four stops reached out of order, two at one street length";
const UNBOUNDED_CASE_NAME: &str = "a streets table with no street bound";
const CANDIDATE_COUNT_MAX: usize = 256;

fn cases() -> Value {
    fixture(include_str!(
        "../../../../test/fixtures/routing/walk-v1/expected.json"
    ))
}

fn case_named<'cases>(cases: &'cases Value, group: &str, name: &str) -> &'cases Value {
    let found = cases
        .get(group)
        .items()
        .iter()
        .find(|case| case.get("name").text() == name);
    let Some(case) = found else {
        panic!("routing walk test: no case named {name}");
    };
    case
}

// The walking rules a manifest entry holds.
fn rules_of(transfer_rules: &Value) -> WalkRules {
    WalkRules {
        walk_radius_m: transfer_rules.get("walkRadiusM").number(),
        walk_speed_m_per_s: transfer_rules.get("walkSpeedMPerS").number(),
        walk_link_count_per_stop_max: transfer_rules.get("walkLinkCountPerStopMax").number(),
    }
}

// The basis a manifest entry names, where it names it as text.
fn basis_text(transfer_rules: &Value) -> Option<&str> {
    match transfer_rules.member("walkBasis") {
        Some(Value::Text(text)) => Some(text),
        _ => None,
    }
}

// The street bound a manifest entry names, read as the number the fixture writes.
fn street_bound(transfer_rules: &Value) -> Option<f64> {
    transfer_rules
        .member("walkStreetMetersMax")
        .map(Value::number)
}

// A microdegree value of a positions column, a whole number the fixture writes.
fn microdegrees(value: f64) -> i32 {
    format!("{value}").parse().unwrap()
}

fn column(values: &Value) -> Vec<i32> {
    values.numbers().into_iter().map(microdegrees).collect()
}

fn positions_of(case: &Value) -> Positions {
    let positions = case.get("positions");
    Positions {
        lat_microdegrees: column(positions.get("latMicrodegrees")),
        lon_microdegrees: column(positions.get("lonMicrodegrees")),
    }
}

fn position_of(case: &Value) -> Position {
    let position = case.get("position");
    Position {
        lon: position.get("lon").number(),
        lat: position.get("lat").number(),
    }
}

fn starts_of(case: &Value) -> Vec<Start> {
    let start = |value: &Value| Start {
        stop: value.get("stop").number(),
        walk_s: value.get("walkS").number(),
    };
    case.get("starts").items().iter().map(start).collect()
}

fn candidates_of(case: &Value) -> Vec<Candidate> {
    let candidate = |value: &Value| Candidate {
        stop: value.get("stop").number(),
        lat: value.get("lat").number(),
        lon: value.get("lon").number(),
    };
    case.get("candidates")
        .items()
        .iter()
        .map(candidate)
        .collect()
}

fn reached_of(case: &Value) -> Vec<ReachedStop> {
    let reached = |value: &Value| ReachedStop {
        stop: value.get("stop").number(),
        street_m: value.get("streetM").number(),
    };
    case.get("stops").items().iter().map(reached).collect()
}

#[test]
fn the_bases_name_a_straight_line_the_streets_and_a_mix() {
    let names = WalkBasis::ALL.map(WalkBasis::name);
    assert_eq!(names, ["straight", "streets", "mixed"]);
}

#[test]
fn a_walk_over_the_streets_searches_at_most_256_candidates() {
    assert_eq!(WALK_CANDIDATE_COUNT_MAX, CANDIDATE_COUNT_MAX);
}

#[test]
fn the_260_stop_case_holds_more_stops_than_the_street_search_keeps() {
    let cases = cases();
    let case = case_named(&cases, "near", BOUND_CASE_NAME);
    let stop_count = positions_of(case).lat_microdegrees.len();
    assert!(stop_count > CANDIDATE_COUNT_MAX);
}

#[test]
fn bases() {
    for case in cases().get("bases").items() {
        let transfer_rules = case.get("transferRules");
        let basis = walk_basis_of(basis_text(transfer_rules), street_bound(transfer_rules));
        assert_eq!(
            basis.name(),
            case.get("basis").text(),
            "case: {}",
            case.get("name").text()
        );
    }
}

#[test]
fn street_walks() {
    for case in cases().get("streetWalks").items() {
        let basis = WalkBasis::named(case.get("basis").text());
        let expected = case.get("isStreetWalk") == &Value::Bool(true);
        assert_eq!(is_street_walk(basis), expected, "basis: {}", basis.name());
    }
}

#[test]
fn a_basis_of_unknown_kind_is_refused() {
    let failure = failure_of(|| WalkBasis::named("teleport"));
    assert_eq!(
        failure.message(),
        "routing walk: a walking basis of unknown kind: teleport"
    );
}

#[test]
fn street_bounds() {
    for case in cases().get("streetBounds").items() {
        let meters = street_meters_max_of(street_bound(case.get("transferRules")));
        assert_eq!(
            meters,
            case.get("meters").number(),
            "case: {}",
            case.get("name").text()
        );
    }
}

#[test]
fn refused_street_bounds() {
    let cases = cases();
    let unbounded = case_named(&cases, "bases", UNBOUNDED_CASE_NAME);
    let refused = [
        (
            street_bound(unbounded.get("transferRules")),
            "routing walk: the street length bound is not a number: undefined",
        ),
        (
            Some(f64::NAN),
            "routing walk: the street length bound is not a number: NaN",
        ),
        (
            Some(f64::INFINITY),
            "routing walk: the street length bound is not a number: Infinity",
        ),
        (
            Some(0.0),
            "routing walk: the street length bound is not positive: 0",
        ),
        (
            Some(-600.0),
            "routing walk: the street length bound is not positive: -600",
        ),
    ];
    for (bound, message) in refused {
        let failure = failure_of(|| street_meters_max_of(bound));
        assert_eq!(failure.message(), message);
    }
}

#[test]
fn starts_near_a_position() {
    for case in cases().get("near").items() {
        let positions = positions_of(case);
        let starts = starts_near(&Near {
            position: position_of(case),
            positions: &positions,
            rules: rules_of(case.get("transferRules")),
        });
        assert_eq!(starts, starts_of(case), "case: {}", case.get("name").text());
    }
}

#[test]
fn candidates_near_a_position() {
    for case in cases().get("near").items() {
        let positions = positions_of(case);
        let candidates = walk_candidates_near(&Near {
            position: position_of(case),
            positions: &positions,
            rules: rules_of(case.get("transferRules")),
        });
        assert_eq!(
            candidates,
            candidates_of(case),
            "case: {}",
            case.get("name").text()
        );
    }
}

#[test]
fn starts_from_the_streets() {
    for case in cases().get("streets").items() {
        let stops = reached_of(case);
        let starts = starts_from_streets(&stops, rules_of(case.get("transferRules")));
        assert_eq!(starts, starts_of(case), "case: {}", case.get("name").text());
    }
}

// Each set of rules the walk refuses, by the rule it breaks, with the
// failure's message.
fn refused_rules(rules: WalkRules) -> [(WalkRules, &'static str); 3] {
    [
        (
            WalkRules {
                walk_radius_m: 0.0,
                ..rules
            },
            "routing walk: the walking radius is not positive: 0",
        ),
        (
            WalkRules {
                walk_speed_m_per_s: 0.0,
                ..rules
            },
            "routing walk: the walking speed is not positive: 0",
        ),
        (
            WalkRules {
                walk_link_count_per_stop_max: 2.5,
                ..rules
            },
            "routing walk: the link count is not whole: 2.5",
        ),
    ]
}

// A query near a position the walk refuses, with the failure's message.
struct RefusedNear {
    position: Position,
    positions: Positions,
    rules: WalkRules,
    failure: &'static str,
}

fn refused_near_queries() -> Vec<RefusedNear> {
    let cases = cases();
    let case = case_named(&cases, "near", NEAR_CASE_NAME);
    let position = position_of(case);
    let positions = positions_of(case);
    let rules = rules_of(case.get("transferRules"));
    let refused = |moved: Position, failure: &'static str| RefusedNear {
        position: moved,
        positions: positions.clone(),
        rules,
        failure,
    };
    let mut queries = vec![
        refused(
            Position {
                lat: f64::NAN,
                ..position
            },
            "routing walk: the position's latitude is not a number: NaN",
        ),
        refused(
            Position {
                lon: f64::NAN,
                ..position
            },
            "routing walk: the position's longitude is not a number: NaN",
        ),
        refused(
            Position {
                lat: 90.5,
                ..position
            },
            "routing walk: the position's latitude is out of range: 90.5",
        ),
        refused(
            Position {
                lon: -180.5,
                ..position
            },
            "routing walk: the position's longitude is out of range: -180.5",
        ),
    ];
    for (broken, failure) in refused_rules(rules) {
        queries.push(RefusedNear {
            position,
            positions: positions.clone(),
            rules: broken,
            failure,
        });
    }
    let shorter = Positions {
        lat_microdegrees: positions.lat_microdegrees.clone(),
        lon_microdegrees: positions.lon_microdegrees[1..].to_vec(),
    };
    queries.push(RefusedNear {
        position,
        positions: shorter,
        rules,
        failure: "routing walk: the position columns differ in length",
    });
    queries
}

#[test]
fn refused_starts_near() {
    for query in refused_near_queries() {
        let failure = failure_of(|| {
            starts_near(&Near {
                position: query.position,
                positions: &query.positions,
                rules: query.rules,
            })
        });
        assert_eq!(failure.message(), query.failure);
    }
}

#[test]
fn refused_candidates_near() {
    for query in refused_near_queries() {
        let failure = failure_of(|| {
            walk_candidates_near(&Near {
                position: query.position,
                positions: &query.positions,
                rules: query.rules,
            })
        });
        assert_eq!(failure.message(), query.failure);
    }
}

#[test]
fn refused_starts_from_the_streets() {
    let cases = cases();
    let case = case_named(&cases, "streets", STREETS_CASE_NAME);
    let stops = reached_of(case);
    for (rules, message) in refused_rules(rules_of(case.get("transferRules"))) {
        let failure = failure_of(|| starts_from_streets(&stops, rules));
        assert_eq!(failure.message(), message);
    }
}
