// Checks the trip path decoder and cache: the decoder reads the shared fixture
// the Elixir tests pin to the server's builder, the stored loop trip 1_1137791
// of route 1_7994, and must find its points and each stop's distance and
// times, and must refuse each case of the shared refusal table with its
// message; the cache is fed paths written out by hand.

use gobusgo_core::math::geodesy::{Between, Position, distance_meters};
use gobusgo_core::trip_path::{
    DecodedPath, ENCODED_NOT_TEXT_MESSAGE, EncodedPath, KeyOf, Point, TRIP_ID_NOT_TEXT_MESSAGE,
    TRIP_PATH_COUNT_MAX, decode_trip_path, trip_path_key, with_trip_paths,
};

use crate::failure_of;
use crate::fixture;
use crate::json::Value;

const DISTANCE_TOLERANCE_M: f64 = 1.0;

fn loop_fixture() -> Value {
    fixture(include_str!(
        "../../../../test/fixtures/one_bus_away/trip_path/encoded_loop.json"
    ))
}

fn refusals() -> Value {
    fixture(include_str!(
        "../../../../test/fixtures/one_bus_away/trip_path/refusals.json"
    ))
}

fn decoded(event: &Value) -> DecodedPath {
    decode_trip_path(EncodedPath {
        trip_id: event.get("trip_id").text(),
        service_date_ms: event.get("service_date_ms").number(),
        points: event.get("points").text(),
        stops: event.get("stops").text(),
    })
}

fn point_of(value: &Value) -> Point {
    let numbers = value.numbers();
    Point {
        longitude: numbers[0],
        latitude: numbers[1],
    }
}

#[test]
fn the_point_count() {
    let fixture = loop_fixture();
    let path = decoded(fixture.get("event"));
    assert_eq!(
        f64::from(u32::try_from(path.points.len()).unwrap()),
        fixture.get("expected").get("pointCount").number()
    );
}

#[test]
fn the_first_point() {
    let fixture = loop_fixture();
    let path = decoded(fixture.get("event"));
    assert_eq!(
        path.points[0],
        point_of(fixture.get("expected").get("firstPoint"))
    );
}

#[test]
fn the_last_point() {
    let fixture = loop_fixture();
    let path = decoded(fixture.get("event"));
    assert_eq!(
        path.points.last().copied(),
        Some(point_of(fixture.get("expected").get("lastPoint")))
    );
}

#[test]
fn the_stop_distances() {
    let fixture = loop_fixture();
    let path = decoded(fixture.get("event"));
    let distances: Vec<f64> = path.stops.iter().map(|stop| stop.distance_meters).collect();
    assert_eq!(
        distances,
        fixture.get("expected").get("stopDistancesM").numbers()
    );
}

#[test]
fn the_arrivals() {
    let fixture = loop_fixture();
    let path = decoded(fixture.get("event"));
    let arrivals: Vec<f64> = path.stops.iter().map(|stop| stop.arrival_seconds).collect();
    assert_eq!(arrivals, fixture.get("expected").get("arrivalS").numbers());
}

#[test]
fn the_departures() {
    let fixture = loop_fixture();
    let path = decoded(fixture.get("event"));
    let departures: Vec<f64> = path
        .stops
        .iter()
        .map(|stop| stop.departure_seconds)
        .collect();
    assert_eq!(
        departures,
        fixture.get("expected").get("departureS").numbers()
    );
}

#[test]
fn the_key() {
    let fixture = loop_fixture();
    let event = fixture.get("event");
    let key = trip_path_key(KeyOf {
        trip_id: event.get("trip_id").text(),
        service_date_ms: event.get("service_date_ms").number(),
    });
    assert_eq!(decoded(event).key, key);
}

// The server measures a stop's distance over the same rounded points by the
// same formula, so the length of the decoded points is the last stop's
// distance.
#[test]
fn the_length_along_the_points() {
    let fixture = loop_fixture();
    let path = decoded(fixture.get("event"));
    let position = |point: &Point| Position {
        lon: point.longitude,
        lat: point.latitude,
    };
    let length_meters: f64 = path
        .points
        .windows(2)
        .map(|pair| {
            distance_meters(Between {
                source: position(&pair[0]),
                target: position(&pair[1]),
            })
        })
        .sum();
    let error = (length_meters - fixture.get("expected").get("lengthM").number()).abs();
    assert!(error <= DISTANCE_TOLERANCE_M, "error: {error}");
}

// The event with the one field a refusal case changes.
fn refused_event(case: &Value, event: &Value) -> Value {
    let Value::Object(members) = event else {
        panic!("trip path test: the event is no object");
    };
    let field = case.get("field").text();
    let value = match case.member("append") {
        Some(append) => Value::Text(format!("{}{}", event.get(field).text(), append.text())),
        None => case.get("value").clone(),
    };
    let changed = members
        .iter()
        .map(|(name, held)| {
            if name == field {
                return (name.clone(), value.clone());
            }
            (name.clone(), held.clone())
        })
        .collect();
    Value::Object(changed)
}

// The message a binding writes for a field of the event that is no text, as
// the core takes text there, or `None` where every text field is text.
fn not_text_failure(event: &Value) -> Option<&'static str> {
    let is_text = |name: &str| matches!(event.get(name), Value::Text(_));
    if !is_text("points") || !is_text("stops") {
        return Some(ENCODED_NOT_TEXT_MESSAGE);
    }
    if !is_text("trip_id") {
        return Some(TRIP_ID_NOT_TEXT_MESSAGE);
    }
    None
}

#[test]
fn refused_paths() {
    let fixture = loop_fixture();
    for case in refusals().get("cases").items() {
        let event = refused_event(case, fixture.get("event"));
        let expected = case.get("failure").text();
        let message = match not_text_failure(&event) {
            Some(message) => message.to_owned(),
            None => failure_of(|| decoded(&event)).message().to_owned(),
        };
        assert_eq!(message, expected, "case: {}", case.get("name").text());
    }
}

fn held_path(name: &str) -> (String, ()) {
    let key = trip_path_key(KeyOf {
        trip_id: &format!("trip_{name}"),
        service_date_ms: 0.0,
    });
    (key, ())
}

fn overflowing_cache() -> Vec<(String, ())> {
    let overflowing = (0..=TRIP_PATH_COUNT_MAX)
        .map(|index| held_path(&index.to_string()))
        .collect();
    with_trip_paths(Vec::new(), overflowing)
}

fn keys(cache: &[(String, ())]) -> Vec<&str> {
    cache.iter().map(|(key, ())| key.as_str()).collect()
}

#[test]
fn the_cache_holds_no_more_paths_than_its_bound() {
    assert_eq!(overflowing_cache().len(), TRIP_PATH_COUNT_MAX);
}

#[test]
fn the_cache_evicts_the_path_put_earliest() {
    let cache = overflowing_cache();
    assert!(!keys(&cache).contains(&held_path("0").0.as_str()));
}

#[test]
fn the_cache_keeps_the_path_put_last() {
    let cache = overflowing_cache();
    let last = held_path(&TRIP_PATH_COUNT_MAX.to_string()).0;
    assert!(keys(&cache).contains(&last.as_str()));
}

#[test]
fn a_path_put_again_moves_to_the_back() {
    let both = with_trip_paths(Vec::new(), vec![held_path("first"), held_path("second")]);
    let moved = with_trip_paths(both, vec![held_path("first")]);
    assert_eq!(keys(&moved), [held_path("second").0, held_path("first").0]);
}
