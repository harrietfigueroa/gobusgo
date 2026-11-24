// Decodes the shared routing snapshot fixtures and compares each file's
// records with the expected records the fixtures hold beside them, then checks
// that each file of the shared refusal table, a fixture with one rule of the
// format broken, is refused for the reason the table names.

use gobusgo_core::routing_snapshot::{
    RefusalReason, decode_connections, decode_positions, decode_stops, decode_transfers,
    decode_trips,
};

use crate::json::Value;
use crate::{edited_bytes, fixture};

const STOPS: &[u8] = include_bytes!("../../../../test/fixtures/routing/v2/stops.bin");
const TRIPS: &[u8] = include_bytes!("../../../../test/fixtures/routing/v2/trips.bin");
const TRANSFERS: &[u8] = include_bytes!("../../../../test/fixtures/routing/v2/transfers.bin");
const CONNECTIONS: &[u8] = include_bytes!("../../../../test/fixtures/routing/v2/connections.bin");
const POSITIONS: &[u8] = include_bytes!("../../../../test/fixtures/routing/v2/positions.bin");

fn expected() -> Value {
    fixture(include_str!(
        "../../../../test/fixtures/routing/v2/expected.json"
    ))
}

fn refusals() -> Value {
    fixture(include_str!(
        "../../../../test/fixtures/routing/v2/refusals.json"
    ))
}

fn file(name: &str) -> &'static [u8] {
    match name {
        "stops" => STOPS,
        "trips" => TRIPS,
        "transfers" => TRANSFERS,
        "connections" => CONNECTIONS,
        "positions" => POSITIONS,
        _ => panic!("routing snapshot test: no file {name}"),
    }
}

// The numbers a column of the expected records holds, one per record.
fn column(records: &Value, name: &str) -> Vec<f64> {
    records
        .items()
        .iter()
        .map(|record| record.get(name).number())
        .collect()
}

// The flags a column of the expected records holds, as the 1 and 0 the
// decoder writes.
fn flags(records: &Value, name: &str) -> Vec<u8> {
    let flag = |record: &Value| match record.get(name) {
        Value::Bool(true) => 1,
        Value::Bool(false) => 0,
        other => panic!("routing snapshot test: {other:?} is no flag"),
    };
    records.items().iter().map(flag).collect()
}

fn numbers<Integer: Copy + Into<f64>>(values: &[Integer]) -> Vec<f64> {
    values.iter().map(|value| (*value).into()).collect()
}

#[test]
fn stops_decode_to_the_expected_records() {
    let expected = expected();
    let stops: Vec<&str> = expected
        .get("stops")
        .items()
        .iter()
        .map(Value::text)
        .collect();
    assert_eq!(decode_stops(STOPS).unwrap(), stops);
}

#[test]
fn trips_decode_to_the_expected_records() {
    let expected = expected();
    let trips = decode_trips(TRIPS).unwrap();
    let records = expected.get("trips").items();
    assert_eq!(trips.len(), records.len());
    for (trip, record) in trips.iter().zip(records) {
        assert_eq!(trip.id, record.get("id").text());
        assert_eq!(trip.route_id, record.get("routeId").text());
        assert_eq!(
            f64::from(trip.service_day_offset),
            record.get("serviceDayOffset").number()
        );
    }
}

#[test]
fn transfers_decode_to_the_expected_records() {
    let expected = expected();
    let records = expected.get("transfers");
    let transfers = decode_transfers(TRANSFERS).unwrap();
    assert_eq!(numbers(&transfers.from_stop), column(records, "fromStop"));
    assert_eq!(numbers(&transfers.to_stop), column(records, "toStop"));
    assert_eq!(numbers(&transfers.duration_s), column(records, "durationS"));
}

#[test]
fn connections_decode_to_the_expected_records() {
    let expected = expected();
    let records = expected.get("connections");
    let connections = decode_connections(CONNECTIONS).unwrap();
    assert_eq!(
        numbers(&connections.departure_s),
        column(records, "departureS")
    );
    assert_eq!(numbers(&connections.arrival_s), column(records, "arrivalS"));
    assert_eq!(
        numbers(&connections.departure_stop),
        column(records, "departureStop")
    );
    assert_eq!(
        numbers(&connections.arrival_stop),
        column(records, "arrivalStop")
    );
    assert_eq!(numbers(&connections.trip), column(records, "trip"));
    assert_eq!(numbers(&connections.sequence), column(records, "sequence"));
    assert_eq!(connections.boarding, flags(records, "boarding"));
    assert_eq!(connections.alighting, flags(records, "alighting"));
}

#[test]
fn positions_decode_to_the_expected_records() {
    let expected = expected();
    let records = expected.get("positions");
    let positions = decode_positions(POSITIONS).unwrap();
    assert_eq!(
        numbers(&positions.lat_microdegrees),
        column(records, "latMicrodegrees")
    );
    assert_eq!(
        numbers(&positions.lon_microdegrees),
        column(records, "lonMicrodegrees")
    );
}

// The reason a decoder refuses `bytes` with, or `None` where it decodes them.
fn refusal_of(decoder: &str, bytes: &[u8]) -> Option<RefusalReason> {
    match decoder {
        "stops" => decode_stops(bytes).err(),
        "trips" => decode_trips(bytes).err(),
        "transfers" => decode_transfers(bytes).err(),
        "connections" => decode_connections(bytes).err(),
        "positions" => decode_positions(bytes).err(),
        _ => panic!("routing snapshot test: no decoder {decoder}"),
    }
}

#[test]
fn refused_files() {
    for case in refusals().get("cases").items() {
        let bytes = edited_bytes(file(case.get("file").text()), case.get("edits"));
        let refusal = refusal_of(case.get("decoder").text(), &bytes);
        let reason = refusal.map(RefusalReason::name);
        assert_eq!(
            reason,
            Some(case.get("reason").text()),
            "case: {}",
            case.get("name").text()
        );
    }
}
