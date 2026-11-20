// Decodes the shared packed container fixture, expanded, and compares the
// values with the expected values the fixture holds beside it, then checks
// that each rule a container, a section cursor, a column, or a positions
// section can break is refused as a value, from the shared refusal table
// beside the fixture. It also checks the kind table against the table file
// beside the fixture. The gzip expansion is a platform driver's, so its cases
// run in the browser suite alone.

use gobusgo_core::packed_container::{
    Column, ColumnRequest, ColumnType, Container, ContainerOptions, FileNameOf, HEADER_BYTES,
    KINDS, PositionsRequest, Refusal, Section, SectionCursor, UNKNOWN_MICRODEGREES,
    decode_container, open_column, open_positions, packed_file_name,
};

use crate::json::Value;
use crate::{edited_bytes, fixture, hex_bytes};

const FIXTURE: &[u8] = include_bytes!("../../../../test/fixtures/packed/core-v1/fixture.bin");
const FIXTURE_KIND: f64 = 0.0;
const FIXTURE_VERSIONS: [f64; 1] = [1.0];
const SECTION_COUNT: f64 = 6.0;
const COORDINATE_COUNT: usize = 2;
const SHA256_BYTES: usize = 32;
const ADDRESS_SHARD_KIND: f64 = 3.0;
const ADDRESS_INDEX_KIND: f64 = 4.0;
const VERSION_OFFSET: usize = 4;

fn expected() -> Value {
    fixture(include_str!(
        "../../../../test/fixtures/packed/core-v1/expected.json"
    ))
}

fn kinds() -> Value {
    fixture(include_str!("../../../../test/fixtures/packed/kinds.json"))
}

fn refusals() -> Value {
    fixture(include_str!(
        "../../../../test/fixtures/packed/core-v1/refusals.json"
    ))
}

const fn options() -> ContainerOptions<'static> {
    ContainerOptions {
        kind: FIXTURE_KIND,
        versions: &FIXTURE_VERSIONS,
        section_count: SECTION_COUNT,
    }
}

fn integers(values: &[f64]) -> Vec<i64> {
    values
        .iter()
        .map(|value| format!("{value}").parse().unwrap())
        .collect()
}

fn column_values(
    container: &Container<'_>,
    section_index: usize,
    column_type: ColumnType,
) -> Vec<i64> {
    let column = open_column(ColumnRequest {
        bytes: FIXTURE,
        section: container.sections[section_index],
        column_type,
        count: f64::from(container.header.record_count),
    })
    .unwrap();
    match column {
        Column::U8(values) => values.into_iter().map(i64::from).collect(),
        Column::U16(values) => values.into_iter().map(i64::from).collect(),
        Column::U32(values) => values.into_iter().map(i64::from).collect(),
        Column::I32(values) => values.into_iter().map(i64::from).collect(),
    }
}

// Each position as its two coordinates, or `None` where it is unknown.
fn position_values(container: &Container<'_>, section_index: usize) -> Vec<Option<[i32; 2]>> {
    let positions = open_positions(PositionsRequest {
        bytes: FIXTURE,
        section: container.sections[section_index],
        count: f64::from(container.header.record_count),
    })
    .unwrap();
    let pairs = positions.latitude.iter().zip(&positions.longitude);
    pairs
        .map(|(&latitude, &longitude)| {
            if latitude == UNKNOWN_MICRODEGREES {
                assert_eq!(longitude, UNKNOWN_MICRODEGREES);
                return None;
            }
            Some([latitude, longitude])
        })
        .collect()
}

fn path_values(container: &Container<'_>, section_index: usize) -> Vec<Vec<[i32; 2]>> {
    let mut cursor = SectionCursor::new(FIXTURE, container.sections[section_index]);
    let mut paths = Vec::new();
    while cursor.remaining() > 0 {
        let points = cursor.read_path();
        assert_eq!(cursor.refusal, None);
        paths.push(
            points
                .chunks(COORDINATE_COUNT)
                .map(|point| [point[0], point[1]])
                .collect(),
        );
    }
    paths
}

fn varint_values(container: &Container<'_>, section_index: usize) -> Vec<i64> {
    let mut cursor = SectionCursor::new(FIXTURE, container.sections[section_index]);
    let mut values = Vec::new();
    while cursor.remaining() > 0 {
        values.push(i64::from(cursor.read_varint()));
        assert_eq!(cursor.refusal, None);
    }
    values
}

fn expected_position(value: &Value) -> Option<[i32; 2]> {
    if *value == Value::Null {
        return None;
    }
    let coordinates = integers(&value.numbers());
    Some([
        coordinates[0].try_into().unwrap(),
        coordinates[1].try_into().unwrap(),
    ])
}

fn expected_path(value: &Value) -> Vec<[i32; 2]> {
    value
        .items()
        .iter()
        .map(|point| expected_position(point).unwrap())
        .collect()
}

#[test]
fn the_expanded_fixture_decodes_to_the_expected_header() {
    let expected = expected();
    let container = decode_container(FIXTURE, options()).unwrap();
    assert_eq!(
        f64::from(container.header.kind),
        expected.get("kind").number()
    );
    assert_eq!(
        f64::from(container.header.version),
        expected.get("version").number()
    );
    assert_eq!(
        f64::from(container.header.record_count),
        expected.get("recordCount").number()
    );
}

#[test]
fn the_expanded_fixture_decodes_to_the_expected_strings() {
    let expected = expected();
    let container = decode_container(FIXTURE, options()).unwrap();
    let strings: Vec<&str> = expected
        .get("strings")
        .items()
        .iter()
        .map(Value::text)
        .collect();
    assert_eq!(container.strings, strings);
}

#[test]
fn the_expanded_fixture_decodes_to_the_expected_columns() {
    let expected = expected();
    let container = decode_container(FIXTURE, options()).unwrap();
    let cases = [
        ("u32", 0, ColumnType::U32),
        ("i32", 1, ColumnType::I32),
        ("u16Strings", 2, ColumnType::U16),
    ];
    for (name, section_index, column_type) in cases {
        let values = column_values(&container, section_index, column_type);
        assert_eq!(
            values,
            integers(&expected.get(name).numbers()),
            "column: {name}"
        );
    }
}

#[test]
fn the_expanded_fixture_decodes_to_the_expected_positions() {
    let expected = expected();
    let container = decode_container(FIXTURE, options()).unwrap();
    let positions: Vec<Option<[i32; 2]>> = expected
        .get("positions")
        .items()
        .iter()
        .map(expected_position)
        .collect();
    assert_eq!(position_values(&container, 3), positions);
}

#[test]
fn the_expanded_fixture_decodes_to_the_expected_paths() {
    let expected = expected();
    let container = decode_container(FIXTURE, options()).unwrap();
    let paths: Vec<Vec<[i32; 2]>> = expected
        .get("paths")
        .items()
        .iter()
        .map(expected_path)
        .collect();
    assert_eq!(path_values(&container, 4), paths);
}

#[test]
fn the_expanded_fixture_decodes_to_the_expected_varints() {
    let expected = expected();
    let container = decode_container(FIXTURE, options()).unwrap();
    assert_eq!(
        varint_values(&container, 5),
        integers(&expected.get("varints").numbers())
    );
}

#[test]
fn the_kind_table_matches_the_table_file() {
    let kinds = kinds();
    let table = kinds.items();
    assert_eq!(table.len(), KINDS.len());
    for (kind, entry) in KINDS.iter().zip(table) {
        assert_eq!(f64::from(kind.number), entry.get("number").number());
        assert_eq!(kind.name, entry.get("name").text());
        assert_eq!(kind.prefix, entry.get("prefix").text());
    }
}

// A container of the fixture's header whose one section is the string table
// `hex` spells.
fn with_table(hex: &str) -> Vec<u8> {
    let table = hex_bytes(hex);
    let mut bytes = FIXTURE[..HEADER_BYTES].to_vec();
    bytes.extend(u32::try_from(table.len()).unwrap().to_le_bytes());
    bytes.extend(table);
    bytes
}

fn container_bytes(bytes: &Value) -> Vec<u8> {
    if let Some(table) = bytes.member("table") {
        return with_table(table.text());
    }
    edited_bytes(FIXTURE, bytes.get("fixture"))
}

#[test]
fn refused_containers() {
    for case in refusals().get("containers").items() {
        let bytes = container_bytes(case.get("bytes"));
        let overrides = case.get("options");
        let versions = overrides.member("versions").map(Value::numbers);
        let refused = decode_container(
            &bytes,
            ContainerOptions {
                kind: overrides.member("kind").map_or(FIXTURE_KIND, Value::number),
                versions: versions.as_deref().unwrap_or(&FIXTURE_VERSIONS),
                section_count: overrides
                    .member("sectionCount")
                    .map_or(SECTION_COUNT, Value::number),
            },
        );
        let reason = refused.err().map(Refusal::name);
        assert_eq!(
            reason,
            Some(case.get("reason").text()),
            "case: {}",
            case.get("name").text()
        );
    }
}

fn whole(bytes: &[u8]) -> Section {
    Section {
        offset: 0,
        byte_length: bytes.len(),
    }
}

#[test]
fn refused_by_a_cursor() {
    for case in refusals().get("cursors").items() {
        let bytes = hex_bytes(case.get("hex").text());
        let mut cursor = SectionCursor::new(&bytes, whole(&bytes));
        match case.get("read").text() {
            "path" => assert_eq!(cursor.read_path(), Vec::<i32>::new()),
            "varint" => assert_eq!(cursor.read_varint(), 0),
            other => panic!("packed test: no read {other}"),
        }
        let reason = cursor.refusal.map(Refusal::name);
        assert_eq!(
            reason,
            Some(case.get("reason").text()),
            "case: {}",
            case.get("name").text()
        );
    }
}

fn column_type(name: &str) -> ColumnType {
    let found = ColumnType::ALL
        .into_iter()
        .find(|candidate| candidate.name() == name);
    found.unwrap_or_else(|| panic!("packed test: no column type {name}"))
}

#[test]
fn refused_when_opened() {
    for case in refusals().get("sections").items() {
        let bytes = hex_bytes(case.get("hex").text());
        let count = case.get("count").number();
        let refused = match case.get("open").text() {
            "positions" => open_positions(PositionsRequest {
                bytes: &bytes,
                section: whole(&bytes),
                count,
            })
            .err(),
            "column" => open_column(ColumnRequest {
                bytes: &bytes,
                section: whole(&bytes),
                column_type: column_type(case.get("columnType").text()),
                count,
            })
            .err(),
            other => panic!("packed test: no opening {other}"),
        };
        let reason = refused.map(Refusal::name);
        assert_eq!(
            reason,
            Some(case.get("reason").text()),
            "case: {}",
            case.get("name").text()
        );
    }
}

// A reader that knows several versions accepts a file of any of them.
#[test]
fn a_reader_of_several_versions_accepts_any_of_them() {
    let mut second_version = FIXTURE.to_vec();
    second_version[VERSION_OFFSET] = 2;
    let versions = [2.0, 3.0];
    let container = decode_container(
        &second_version,
        ContainerOptions {
            versions: &versions,
            ..options()
        },
    )
    .unwrap();
    assert_eq!(container.header.version, 2);
}

#[test]
fn an_address_shards_file_name() {
    let sha256 = "ab".repeat(SHA256_BYTES);
    let name = packed_file_name(FileNameOf {
        kind: ADDRESS_SHARD_KIND,
        sha256: &sha256,
    });
    assert_eq!(name, format!("addresses-{sha256}.bin.gz"));
}

#[test]
fn an_address_indexs_file_name() {
    let sha256 = "ab".repeat(SHA256_BYTES);
    let name = packed_file_name(FileNameOf {
        kind: ADDRESS_INDEX_KIND,
        sha256: &sha256,
    });
    assert_eq!(name, format!("addresses-index-{sha256}.bin.gz"));
}
